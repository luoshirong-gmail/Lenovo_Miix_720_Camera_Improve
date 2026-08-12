// ============================================================
// camera-router.c — 整合组件 (C 实现, GStreamer C API)
// ============================================================
// 架构 (机制经 gst-launch C 层验证):
//   A. 主 pipeline 常驻: videotestsrc(black) → input-selector → v4l2sink
//      → video99 永远有 writer, 格式永远有效
//   B. 增强链动态增删: v4l2src→jpegdec→glupload→glcolorconvert→glshader
//      →glcolorconvert→gldownload→queue → selector request pad
//      - reader 打开: 整链动态添加, link 到 request pad, 切 active-pad
//      - reader 关闭: 切回静态帧, 整链移除 → 真正释放 /dev/video14
//   C. inotify 监听 video99 open/close
// ============================================================
#include <gst/gst.h>
#include <gst/video/video.h>
#include <sys/inotify.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <stdbool.h>
#include <ctype.h>
#include <errno.h>
#include <time.h>
#include <dirent.h>

#define SRC_DEVICE "/dev/video14"
#define SINK_DEVICE "/dev/video99"
#define SRC_W 1280
#define SRC_H 720
#define OUT_W 1920
#define OUT_H 1080
#define FPS 30

// 延迟切换: 增强链从激活到首帧实测 ~0.5s, 设 0.7s 等数据积压
// (OV5670 项目是 3s — libcamera 启动慢; USB 摄像头 v4l2src+jpegdec+GL 更快,
//  已按本摄像头量身定制实测值)
#define SWITCH_DELAY_MS 700

// 项目目录 (make_shader.py 定位) — 合并项目 2026-08-08: 原 USB_Camera_Enhancement
/* ⚠️ 2026-08-10 (发布净化): PROJECT_DIR 运行时推导 — 不再硬编码
 * 用户主目录路径 (可执行文件在 front_camera/pipeline/, 上溯 1 级) */
static char g_project_dir[512] = { 0 };
static const char *get_project_dir(void) {
    if (g_project_dir[0])
        return g_project_dir;
    char exe[512];
    ssize_t n = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
    if (n <= 0) {
        strcpy(g_project_dir, ".");
        return g_project_dir;
    }
    exe[n] = '\0';
    char *slash = strrchr(exe, '/');     /* 去掉 /camera-router */
    if (slash) *slash = '\0';
    slash = strrchr(exe, '/');           /* 再去一级 = front_camera */
    if (slash) *slash = '\0';
    snprintf(g_project_dir, sizeof(g_project_dir), "%s", exe);
    return g_project_dir;
}
#define PROJECT_DIR get_project_dir()

// shader 文件路径 (生成后载入)
#define FRAG_PATH "/tmp/camera-router.frag"

// ---- global state ----
static GstElement *pipeline = NULL;
static GstElement *selector = NULL;
static GstPad *idle_pad = NULL;      // sink_0 (videotestsrc 常驻)
static GstPad *enhance_pad = NULL;   // request pad (sink_1, 动态)
static GstElement *enhance_chain[9]; // 动态增强链元素 (v4l2src..gldownload, queue, capsfilter)
static int enhance_count = 0;
static bool enhance_active = false;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

// 延迟切换 timer (激活增强链后等首帧再切 active-pad)
static guint switch_timer_id = 0;

static void log_msg(const char *fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    time_t t = time(NULL);
    struct tm *tm = localtime(&t);
    fprintf(stderr, "[%02d:%02d:%02d] %s\n", tm->tm_hour, tm->tm_min, tm->tm_sec, buf);
    fflush(stderr);
}

// ---------- shader ----------

static char *load_fragment(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = malloc(size + 1);
    if (!buf) { fclose(f); return NULL; }
    size_t n = fread(buf, 1, size, f);
    buf[n] = '\0';
    fclose(f);
    return buf;
}

// shader 缺失时调用 make_shader.py 生成 (systemd 启动时无预生成依赖)
static bool ensure_fragment(void) {
    if (access(FRAG_PATH, R_OK) == 0)
        return true;
    log_msg("shader %s 缺失, 调用 make_shader.py 生成...", FRAG_PATH);
    char cmd[512];
    snprintf(cmd, sizeof(cmd),
        "cd %s && python3 scripts/make_shader.py shaders/enhance.frag %s %d %d",
        PROJECT_DIR, FRAG_PATH, SRC_W, SRC_H);
    int rc = system(cmd);
    if (rc != 0 || access(FRAG_PATH, R_OK) != 0) {
        log_msg("ERROR: make_shader.py failed (rc=%d)", rc);
        return false;
    }
    log_msg("shader 已生成: %s", FRAG_PATH);
    return true;
}

// ---------- 统一 caps (两条链必须完全一致, 防 selector 切换重建 pool) ----------
// 2026-08-08 修复: 增强链 gldownload 输出带 jpegdec 残留的 multiview-flags,
// idle 链 (videotestsrc) 无此字段 → selector 切换时 caps 变化 → v4l2sink
// 重建 buffer pool → 受 queue max-size-buffers 限制缩到 2 → PipeWire 需 ≥3
// → "can't allocate enough buffers 2 < 3" (第二次打开失败)。
// 修复: 三处 capsfilter (idle 链 / 增强链 / selector→sink) 都用本函数,
// 字段完全一致 (实测: 两条链都能强制 multiview-flags=0, 见测试 A/C)。
static GstCaps *make_full_caps(void) {
    return gst_caps_new_simple("video/x-raw",
        "width", G_TYPE_INT, OUT_W, "height", G_TYPE_INT, OUT_H,
        "format", G_TYPE_STRING, "NV12",
        "framerate", GST_TYPE_FRACTION, FPS, 1,
        "multiview-mode", G_TYPE_STRING, "mono",
        "multiview-flags", GST_TYPE_VIDEO_MULTIVIEW_FLAGS, 0,
        "pixel-aspect-ratio", GST_TYPE_FRACTION, 1, 1,
        "interlace-mode", G_TYPE_STRING, "progressive", NULL);
}

// ---------- build pipeline (resident) ----------

static bool build_pipeline(void) {
    GstElement *idle, *q0, *sink, *up0, *sh0, *dl0;
    GstCaps *caps;

    idle = gst_element_factory_make("videotestsrc", "idle_src");
    q0 = gst_element_factory_make("queue", "idle_q");
    // 静态帧分支走 GL: 让 pipeline 启动时就建立 GL 上下文
    // (动态添加的增强链 GL 元素才能继承上下文)
    up0 = gst_element_factory_make("glupload", "idle_up");
    sh0 = gst_element_factory_make("glshader", "idle_sh");
    dl0 = gst_element_factory_make("gldownload", "idle_dl");
    selector = gst_element_factory_make("input-selector", "sel");
    sink = gst_element_factory_make("v4l2sink", "router_sink");
    pipeline = gst_pipeline_new("camera_router");
    if (!idle || !q0 || !up0 || !sh0 || !dl0 || !selector || !sink || !pipeline) {
        log_msg("ERROR: element creation failed");
        return false;
    }

    g_object_set(idle, "pattern", 2, "is-live", TRUE, "do-timestamp", TRUE, NULL);
    g_object_set(selector, "sync-streams", TRUE, NULL);
    g_object_set(sink, "device", SINK_DEVICE, "sync", FALSE, NULL);

    char *frag = load_fragment(FRAG_PATH);
    if (!frag) {
        log_msg("ERROR: cannot load shader %s", FRAG_PATH);
        return false;
    }
    g_object_set(sh0, "fragment", frag, NULL);
    free(frag);

    gst_bin_add_many(GST_BIN(pipeline), idle, q0, up0, sh0, dl0, selector, sink, NULL);

    caps = make_full_caps();
    if (!gst_element_link_filtered(idle, q0, caps)) {
        log_msg("ERROR: idle->q0 link failed");
        gst_caps_unref(caps);
        return false;
    }
    gst_caps_unref(caps);

    // GL 链: q0 -> glupload -> glcolorconvert -> glshader -> glcolorconvert
    //      -> gldownload -> selector
    GstElement *cc0 = gst_element_factory_make("glcolorconvert", "idle_cc1");
    GstElement *cc1 = gst_element_factory_make("glcolorconvert", "idle_cc2");
    if (!cc0 || !cc1) {
        log_msg("ERROR: glcolorconvert creation failed");
        return false;
    }
    gst_bin_add_many(GST_BIN(pipeline), cc0, cc1, NULL);
    if (!gst_element_link(q0, up0) || !gst_element_link(up0, cc0) ||
        !gst_element_link(cc0, sh0) || !gst_element_link(sh0, cc1) ||
        !gst_element_link(cc1, dl0)) {
        log_msg("ERROR: idle GL chain link failed");
        return false;
    }

    idle_pad = gst_element_request_pad_simple(selector, "sink_%u");
    if (!idle_pad) {
        log_msg("ERROR: selector sink_0 request failed");
        return false;
    }
    // ⚠️ 2026-08-08: idle 链 gldownload 之后必须加 capsfilter (与增强链对称)!
    // GL 链 (glupload→...→gldownload) 会丢失 videotestsrc 入口 capsfilter
    // 强制字段中的 interlace-mode → 到 selector 的 caps 字段集合与增强链不同
    // → selector 切换时 v4l2sink 重建 pool → PipeWire (portal 消费端, 持续持 fd
    //   不重新协商) 旧映射失效 → 黑帧定格。增强链的 capsfilter 在 gldownload 后,
    // idle 链也必须一致 (实测: gldownload 后 capsfilter 输出含 interlace-mode)。
    GstElement *idle_out = gst_element_factory_make("capsfilter", "idle_out_caps");
    if (!idle_out) {
        log_msg("ERROR: idle_out capsfilter creation failed");
        return false;
    }
    gst_bin_add(GST_BIN(pipeline), idle_out);
    caps = make_full_caps();
    g_object_set(idle_out, "caps", caps, NULL);
    gst_caps_unref(caps);
    if (!gst_element_link(dl0, idle_out)) {
        log_msg("ERROR: dl0->idle_out link failed");
        return false;
    }
    GstPad *q0_src = gst_element_get_static_pad(idle_out, "src");
    if (gst_pad_link(q0_src, idle_pad) != GST_PAD_LINK_OK) {
        log_msg("ERROR: idle_out->selector link failed");
        return false;
    }
    gst_object_unref(q0_src);
    // 注意: active-pad 不在 build 时设置 (PLAYING 前设置 request pad 会 double free)
    // 在 main 里 PLAYING 成功后设置

    caps = make_full_caps();
    if (!gst_element_link_filtered(selector, sink, caps)) {
        log_msg("ERROR: selector->sink link failed");
        return false;
    }
    gst_caps_unref(caps);
    return true;
}

// ---------- enhance chain (dynamic) ----------

static bool build_enhance_chain(void) {
    char *frag = load_fragment(FRAG_PATH);
    if (!frag) {
        log_msg("ERROR: cannot load shader %s", FRAG_PATH);
        return false;
    }

    enhance_chain[0] = gst_element_factory_make("v4l2src", "enh_src");
    enhance_chain[1] = gst_element_factory_make("jpegdec", "enh_jdec");
    enhance_chain[2] = gst_element_factory_make("glupload", "enh_upload");
    enhance_chain[3] = gst_element_factory_make("glcolorconvert", "enh_cc1");
    enhance_chain[4] = gst_element_factory_make("glshader", "enh_shader");
    enhance_chain[5] = gst_element_factory_make("glcolorconvert", "enh_cc2");
    enhance_chain[6] = gst_element_factory_make("gldownload", "enh_dl");
    enhance_chain[7] = gst_element_factory_make("queue", "enh_q");
    enhance_chain[8] = gst_element_factory_make("capsfilter", "enh_caps");
    enhance_count = 9;

    for (int i = 0; i < enhance_count; i++) {
        if (!enhance_chain[i]) {
            log_msg("ERROR: enhance element %d creation failed", i);
            return false;
        }
    }
    g_object_set(enhance_chain[0], "device", SRC_DEVICE, "do-timestamp", TRUE, NULL);
    g_object_set(enhance_chain[4], "fragment", frag, NULL);
    // buffer pool 下限: v4l2loopback MIN-3 补丁只提升"无竞争 writer"的 REQBUFS;
    // 增强链激活时 reader 在场 (has_other_owners=true) → 不触发 → pool 会随
    // queue 缩到 2 → PipeWire 要 ≥3 → "can't allocate enough buffers 2 < 3"
    // (第二次打开失败, 2026-08-08 实测复现)。2→4 保证重建后仍 ≥3。
    g_object_set(enhance_chain[7], "max-size-buffers", 4, "leaky", 2, NULL);
    // 增强链输出 caps 强制与 idle 链完全一致 (multiview-flags=0 等),
    // 消除 jpegdec 残留字段 → selector 切换零重建 (2026-08-08 修复)。
    GstCaps *ecaps = make_full_caps();
    g_object_set(enhance_chain[8], "caps", ecaps, NULL);
    gst_caps_unref(ecaps);
    free(frag);
    return true;
}

// 延迟切换: 增强链启动完成 (首帧已积压在 queue) 后切 active-pad
static gboolean switch_to_enhance_cb(gpointer user_data) {
    (void)user_data;
    pthread_mutex_lock(&lock);
    if (enhance_active && enhance_pad) {
        g_object_set(selector, "active-pad", enhance_pad, NULL);
        log_msg("切换 active-pad → 增强链 (延迟 %dms)", SWITCH_DELAY_MS);
    }
    switch_timer_id = 0;
    pthread_mutex_unlock(&lock);
    return G_SOURCE_REMOVE;
}

static bool activate_enhance(void) {
    GstCaps *caps;
    GstPad *src_pad;

    pthread_mutex_lock(&lock);
    if (enhance_active) {
        pthread_mutex_unlock(&lock);
        return true;
    }

    if (!build_enhance_chain()) {
        log_msg("ERROR: build_enhance_chain failed");
        pthread_mutex_unlock(&lock);
        return false;
    }

    for (int i = 0; i < enhance_count; i++)
        gst_bin_add(GST_BIN(pipeline), enhance_chain[i]);

    caps = gst_caps_new_simple("image/jpeg",
        "width", G_TYPE_INT, SRC_W, "height", G_TYPE_INT, SRC_H,
        "framerate", GST_TYPE_FRACTION, FPS, 1, NULL);
    if (!gst_element_link_filtered(enhance_chain[0], enhance_chain[1], caps)) {
        log_msg("ERROR: v4l2src->jpegdec link failed");
        gst_caps_unref(caps);
        goto fail;
    }
    gst_caps_unref(caps);

    for (int i = 1; i < enhance_count - 1; i++) {
        if (!gst_element_link(enhance_chain[i], enhance_chain[i + 1])) {
            log_msg("ERROR: enhance link %d->%d failed", i, i + 1);
            goto fail;
        }
    }

    // link capsfilter -> selector REQUEST pad (增强链末端是 capsfilter[8])
    enhance_pad = gst_element_request_pad_simple(selector, "sink_%u");
    if (!enhance_pad) {
        log_msg("ERROR: request pad failed");
        goto fail;
    }
    src_pad = gst_element_get_static_pad(enhance_chain[8], "src");
    if (gst_pad_link(src_pad, enhance_pad) != GST_PAD_LINK_OK) {
        log_msg("ERROR: capsfilter->request pad link failed");
        gst_object_unref(src_pad);
        goto fail;
    }
    gst_object_unref(src_pad);

    // sync states to parent (PLAYING)
    for (int i = 0; i < enhance_count; i++)
        gst_element_sync_state_with_parent(enhance_chain[i]);

    gst_element_set_state(selector, GST_STATE_PLAYING); // ensure selector active

    // 延迟切换 active-pad (ov5670 优化): 增强链首帧实测 ~0.5s,
    // 等数据积压 (0.7s) 后切换, 切换瞬间即有帧 (避免黑帧/卡顿)
    if (switch_timer_id)
        g_source_remove(switch_timer_id);
    switch_timer_id = g_timeout_add(SWITCH_DELAY_MS, switch_to_enhance_cb, NULL);

    enhance_active = true;
    pthread_mutex_unlock(&lock);
    log_msg("增强已激活 (video14 打开, %d 元素, %dms 后切换)", enhance_count, SWITCH_DELAY_MS);
    return true;

fail:
    for (int i = 0; i < enhance_count; i++)
        gst_bin_remove(GST_BIN(pipeline), enhance_chain[i]);
    enhance_count = 0;
    if (enhance_pad) {
        gst_element_release_request_pad(selector, enhance_pad);
        enhance_pad = NULL;
    }
    pthread_mutex_unlock(&lock);
    return false;
}

static void deactivate_enhance(void) {
    GstPad *src_pad;

    pthread_mutex_lock(&lock);
    if (!enhance_active) {
        pthread_mutex_unlock(&lock);
        return;
    }

    // 清理未触发的延迟切换 timer
    if (switch_timer_id) {
        g_source_remove(switch_timer_id);
        switch_timer_id = 0;
    }
    // 先切回静态帧
    g_object_set(selector, "active-pad", idle_pad, NULL);
    g_usleep(200000);

    if (enhance_pad) {
        src_pad = gst_element_get_static_pad(enhance_chain[8], "src");
        if (src_pad) {
            gst_pad_unlink(src_pad, enhance_pad);
            gst_object_unref(src_pad);
        }
        // release_request_pad 内部会 unref pad, 不能再手动 unref (double free!)
        gst_element_release_request_pad(selector, enhance_pad);
        enhance_pad = NULL;
    }

    for (int i = 0; i < enhance_count; i++) {
        gst_element_set_state(enhance_chain[i], GST_STATE_NULL);
        gst_bin_remove(GST_BIN(pipeline), enhance_chain[i]);
    }
    enhance_count = 0;
    enhance_active = false;
    pthread_mutex_unlock(&lock);
    log_msg("增强已停用 (video14 释放)");
}

// ---------- reader check ----------

static bool has_real_reader(void) {
    // 直接扫描 /proc: 找持有 SINK_DEVICE fd 的真实 reader 进程
    // (不用 popen/fuser — 子进程会继承 fd 造成误检)
    DIR *dir = opendir("/proc");
    if (!dir) return false;
    struct dirent *ent;
    bool found = false;
    while ((ent = readdir(dir)) && !found) {
        if (!isdigit(ent->d_name[0])) continue;
        char fdpath[128], link[256];
        snprintf(fdpath, sizeof(fdpath), "/proc/%s/fd", ent->d_name);
        DIR *fddir = opendir(fdpath);
        if (!fddir) continue;
        struct dirent *fent;
        while ((fent = readdir(fddir)) && !found) {
            if (!isdigit(fent->d_name[0])) continue;
            snprintf(link, sizeof(link), "%s/%s", fdpath, fent->d_name);
            ssize_t n = readlink(link, link, sizeof(link) - 1);
            if (n <= 0) continue;
            link[n] = 0;
            if (strstr(link, SINK_DEVICE) == NULL) continue;
            // 持有 video99 fd 的进程 — 检查是否真实 reader
            char cmdpath[128], cmdline[512] = "";
            snprintf(cmdpath, sizeof(cmdpath), "/proc/%s/cmdline", ent->d_name);
            FILE *cf = fopen(cmdpath, "r");
            if (cf) {
                size_t cn = fread(cmdline, 1, sizeof(cmdline) - 1, cf);
                cmdline[cn] = 0;
                fclose(cf);
                for (size_t i = 0; i < cn; i++) if (cmdline[i] == 0) cmdline[i] = ' ';
            }
            // ⚠️ 2026-08-08: pipewire/wireplumber 不再排除!
            // 之前无条件排除 → Snapshot 走 portal (wireplumber 路径) 时,
            // video99 fd 由 pipewire 进程持有 (spa-v4l2 在 pipewire 内),
            // 被排除 → IN_CLOSE 复查误判"无 reader" → 增强链被拆 → 全黑
            // 且永不恢复 (fd 已打开无新 IN_OPEN)。video99 是"目标虚拟设备",
            // pipewire 持它 = portal 消费端代理 = 真实 reader (ov5670 Phase 19 同款)。
            // wireplumber 枚举的瞬时 open/close 无需特殊处理: IN_CLOSE 复查时
            // 枚举早已结束 (fd 已关), 自然判定无 reader → 停用。
            if (strstr(cmdline, "camera-router")) continue;  // 自己
            log_msg("  reader 检测: PID=%s cmd=%s", ent->d_name, cmdline);
            found = true;
        }
        closedir(fddir);
    }
    closedir(dir);
    return found;
}

// ---------- inotify monitor (thread) ----------

static void *monitor_thread(void *arg) {
    int fd = inotify_init();
    if (fd < 0) {
        log_msg("ERROR: inotify_init failed");
        return NULL;
    }
    int wd = inotify_add_watch(fd, SINK_DEVICE, IN_OPEN | IN_CLOSE);
    if (wd < 0) {
        log_msg("ERROR: inotify_add_watch failed: %s", strerror(errno));
        close(fd);
        return NULL;
    }
    log_msg("监控启动: inotify 监听 %s", SINK_DEVICE);

    char buf[4096];
    while (true) {
        ssize_t len = read(fd, buf, sizeof(buf));
        if (len <= 0) { g_usleep(500000); continue; }
        for (ssize_t i = 0; i < len; ) {
            struct inotify_event *ev = (struct inotify_event *)&buf[i];
            if (ev->mask & IN_OPEN) {
                log_msg("检测到 OPEN → 激活增强");
                activate_enhance();
            } else if (ev->mask & IN_CLOSE) {
                log_msg("检测到 CLOSE → 检查 reader");
                if (!has_real_reader())
                    deactivate_enhance();
            }
            i += sizeof(struct inotify_event) + ev->len;
        }
    }
    close(fd);
    return NULL;
}

// ---------- main ----------

int main(int argc, char **argv) {
    gst_init(&argc, &argv);

    if (!ensure_fragment()) {
        log_msg("ERROR: shader generation failed");
        return 1;
    }

    if (!build_pipeline()) {
        log_msg("ERROR: build_pipeline failed");
        return 1;
    }

    GstStateChangeReturn ret = gst_element_set_state(pipeline, GST_STATE_PLAYING);
    if (ret == GST_STATE_CHANGE_FAILURE) {
        log_msg("ERROR: pipeline PLAYING failed");
        return 1;
    }
    // 等待进入 PLAYING (live 源异步 preroll)
    GstState state;
    GstStateChangeReturn sr = gst_element_get_state(pipeline, &state, NULL, 10 * GST_SECOND);
    if (sr == GST_STATE_CHANGE_FAILURE || state == GST_STATE_VOID_PENDING) {
        log_msg("ERROR: pipeline state failure (sr=%d state=%d)", sr, state);
        return 1;
    }
    // 元素可能已全 PLAYING 但 live pipeline get_state 返回 PAUSED (异步确认)
    if (state != GST_STATE_PLAYING) {
        log_msg("WARN: pipeline get_state=%d (live async), checking elements...", state);
        // 检查 v4l2sink 是否真的在写 (video99 有格式 = 数据在流)
        if (access(SINK_DEVICE, F_OK) == 0) {
            log_msg("INFO: %s 存在, 继续启动 (writer 由 pipeline 持有)", SINK_DEVICE);
        }
    }
    // PLAYING 后设置 active-pad (build 时设置会 double free)
    g_object_set(selector, "active-pad", idle_pad, NULL);
    log_msg("camera-router 启动: %s 常驻 writer (静态帧)", SINK_DEVICE);

    pthread_t th;
    pthread_create(&th, NULL, monitor_thread, NULL);

    // 主循环 (Ctrl+C 退出)
    GMainLoop *loop = g_main_loop_new(NULL, FALSE);
    g_main_loop_run(loop);

    if (enhance_active)
        deactivate_enhance();
    gst_element_set_state(pipeline, GST_STATE_NULL);
    gst_object_unref(pipeline);
    return 0;
}
