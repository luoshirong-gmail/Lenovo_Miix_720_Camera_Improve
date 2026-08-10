// ov5670-router.c — C' 方案 (2026-08-07, 纯 universalization 版, 无对焦轮询)
// 极简架构: libcamerasrc(PAUSED 常驻) → videoconvert → capsfilter
// → cam_q_out → v4l2sink(/dev/video16)。无 idle 链、无 input-selector。
//
// 背景 (2026-08-07 实测确认):
//  - selector 非 active 时 cam 链不推帧 (loop 等下游 pool 协商, queue 永远 0)
//  - cam_src 从 READY 单独切 PLAYING (重新 open) 后 loop 不推帧 (libcamera 出帧
//    但 GStreamer 不推) — gst-launch 全部一起 PLAYING (L3 291 帧) 正常
//  - CAM6 已在 wireplumber 屏蔽 (51-libcamera-disable-cam6.conf) → router 独占,
//    PAUSED 持有 acquire 无副作用 (物理后摄不给应用, 虚拟 video16 替代)
//
// C' 方案:
//  - cam 链 PAUSED 常驻 (open/acquire/配置在 pipeline 启动时完成 — 与 gst-launch
//    语义对齐; PAUSED 不流 → CAM6 无硬件流、CPU 0)
//  - activate:  cam_src PAUSED→PLAYING (只开流, 不重新 open) → 真实帧
//  - deactivate: cam_src PLAYING→PAUSED (停流, 保持 open/acquire)
//  - 无 idle/selector: 没有 user 时不需要推黑帧 (推给谁看?)
//  - v4l2sink 常驻打开 video16 (writer 角色) → wireplumber 枚举正常
//    (QUERYCAP/ENUM_FMT(D-1)/ENUM_FRAMEINTERVALS(v4l2sink 在线→离散) 全读操作,
//    不需要 CAM6 推流)
//
// watchdog: inotify IN_OPEN/IN_CLOSE → 延迟 CONFIRM_MS 复查 has_real_reader()
//  (wireplumber 枚举是瞬时 open/close 必须排除; 持续打开才算 reader)
//  → activate/deactivate。
//
// 2026-08-07 纯 C' 化: 移除对焦逻辑 (af socket 线程/状态机/watchdog/
// v4l2 poll 轮询/af-mode 设置) — libcamera 0.7 IPU3 AF 自动, 无需干预。

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>
#include <ctype.h>
#include <time.h>
#include <unistd.h>
#include <dirent.h>
#include <errno.h>
#include <pthread.h>
#include <sys/inotify.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/ioctl.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <gst/gst.h>

#define SINK_DEVICE     "/dev/video16"
#define CAMERA_ID       "\\_SB_.PCI0.I2C2.CAM6"
#define OUT_W           2560
#define OUT_H           1920
#define OUT_FPS         29

// ---- globals ----
static GstElement *pipeline = NULL;
static GstElement *cam_src = NULL;     // libcamerasrc (状态控制: PAUSED↔PLAYING)
static bool cam_active = false;
/* ⚠️ 2026-08-10 (无应用误对焦修复): reader 连续判定计数 (±3 = 3s 一致
 * 才 activate/deactivate) — inotify 复查与定期复查共用 (跨线程, 简单 int) */
static int reader_streak = 0;
/* ⚠️ 2026-08-10 (扫描中断修复): 单次对焦扫描中 (临时 auto) — abs 忽略 */
static bool af_scanning = false;
/* ⚠️ 2026-08-10 (兜底计时取消): AfState 完成检测到扫描结束时, 取消
 * 30s 兜底定时器 (否则它仍在跑, 30s 后重复回 manual; 连续触发时旧
 * timer 还会干扰新扫描) */
static guint af_state_check_timer = 0;
static guint af_single_scan_timer = 0;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static FILE *logf = NULL;

static void log_msg(const char *fmt, ...) {
    time_t t = time(NULL);
    struct tm *tm = localtime(&t);
    char ts[32];
    strftime(ts, sizeof(ts), "%H:%M:%S", tm);
    va_list ap;
    va_start(ap, fmt);
    if (logf) {
        fprintf(logf, "[%s] ", ts);
        vfprintf(logf, fmt, ap);
        fputc('\n', logf);
        fflush(logf);
    }
    va_end(ap);
}

// ---------- pipeline build ----------
// camera-name 不能放 parse 字符串里! gst_parse_launch 对双引号属性值做双层
// 转义 (字符串级 \\→\, 属性值级 \_→丢) → CAM6 的 \ 被吃光 → "Could not find
// a camera named '_SB_...'" (实测)。parse 后 g_object_set 直接设置。
static bool build_pipeline(void) {
    char desc[1600];
    snprintf(desc, sizeof(desc),
        "libcamerasrc name=cam_src src::stream-role=still-capture "
        "! videoconvert "
        "! video/x-raw,format=NV12,width=%d,height=%d,framerate=%d/1,"
        "colorimetry=bt601,multiview-mode=mono,pixel-aspect-ratio=1/1,"
        "interlace-mode=progressive "
        "! queue name=cam_q_out max-size-buffers=4 leaky=2 "
        "! v4l2sink device=%s sync=false",
        OUT_W, OUT_H, OUT_FPS, SINK_DEVICE);
    GError *perr = NULL;
    pipeline = gst_parse_launch(desc, &perr);
    if (!pipeline) {
        log_msg("ERROR: gst_parse_launch failed: %s", perr ? perr->message : "?");
        if (perr) g_error_free(perr);
        return false;
    }
    cam_src = gst_bin_get_by_name(GST_BIN(pipeline), "cam_src");
    if (!cam_src) {
        log_msg("ERROR: get cam_src failed");
        return false;
    }
    // camera-name 用 g_object_set 直接设置 (绕开 parse 转义; NULL 状态可设)
    g_object_set(cam_src, "camera-name", CAMERA_ID, NULL);
    // ⚠️ 纯 C': 不设 af-mode — libcamera 0.7 IPU3 AF 自动 (README 经验:
    //    "libcamera 0.7 IPU3 AF 自动 (不要设 af-mode=2)")
    log_msg("pipeline 构建完成 (C' 极简): libcamerasrc(PAUSED 常驻)→videoconvert→capsfilter→queue→v4l2sink");
    return true;
}

// ---------- activate / deactivate ----------

static bool activate_camera(void) {
    pthread_mutex_lock(&lock);
    if (cam_active) {
        pthread_mutex_unlock(&lock);
        return true;
    }
    // C': PAUSED→PLAYING (只开流, 不重新 open — open/acquire 在 pipeline 启动
    // 时已完成, 与 gst-launch L3 291 帧的语义对齐)
    if (gst_element_sync_state_with_parent(cam_src) == GST_STATE_CHANGE_FAILURE) {
        log_msg("ERROR: cam_src sync PLAYING 失败");
        pthread_mutex_unlock(&lock);
        return false;
    }
    cam_active = true;
    pthread_mutex_unlock(&lock);
    log_msg("OV5670 已激活 (cam PLAYING, 真实流)");
    return true;
}

static void deactivate_camera(void) {
    pthread_mutex_lock(&lock);
    if (!cam_active) {
        pthread_mutex_unlock(&lock);
        return;
    }
    // C'': 2026-08-10 (无应用误对焦修复): PAUSED 不停流 — libcamerasrc
    // PLAYING_TO_PAUSED 不停 task (gstlibcamerasrc.cpp 993) + libcamera
    // request 循环继续 → IPA 持续有帧 → 无应用时 continuous 对焦一直跑
    // (用户实测)。改 READY: camera 保持 open (NULL_TO_READY 才 open) 但
    // 未 start → IPA 无帧。activate 时 sync_state_with_parent 恢复。
    gst_element_set_state(cam_src, GST_STATE_READY);
    cam_active = false;
    pthread_mutex_unlock(&lock);
    log_msg("OV5670 已释放 (cam READY, 停流 camera 未 start)");
}

// ---------- reader check (轮询 /proc) ----------

/* 排除自己 — cmdline + exe 双保险
 * (exec -a 改名启动时 cmdline 失配, /proc/PID/exe 软链接仍指向真实二进制) */
static bool is_self_router(const char *pid) {
    char cmdpath[128], cmdline[512] = "";
    snprintf(cmdpath, sizeof(cmdpath), "/proc/%s/cmdline", pid);
    FILE *cf = fopen(cmdpath, "r");
    if (cf) {
        size_t cn = fread(cmdline, 1, sizeof(cmdline) - 1, cf);
        cmdline[cn] = 0;
        fclose(cf);
        if (strstr(cmdline, "ov5670-router")) return true;
    }
    char expath[128], exe[256] = "";
    snprintf(expath, sizeof(expath), "/proc/%s/exe", pid);
    ssize_t n = readlink(expath, exe, sizeof(exe) - 1);
    if (n > 0) {
        exe[n] = 0;
        if (strstr(exe, "ov5670-router")) return true;
    }
    return false;
}

static bool has_real_reader(void) {
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
            char target[256];
            ssize_t n = readlink(link, target, sizeof(target) - 1);
            if (n <= 0) continue;
            target[n] = 0;
            if (strstr(target, SINK_DEVICE) == NULL) continue;
            char cmdpath[128], cmdline[512] = "";
            snprintf(cmdpath, sizeof(cmdpath), "/proc/%s/cmdline", ent->d_name);
            FILE *cf = fopen(cmdpath, "r");
            if (cf) {
                size_t cn = fread(cmdline, 1, sizeof(cmdline) - 1, cf);
                cmdline[cn] = 0;
                fclose(cf);
                for (size_t i = 0; i < cn; i++) if (cmdline[i] == 0) cmdline[i] = ' ';
            }
            if (strstr(cmdline, "wireplumber")) {
                /* ⚠️ 2026-08-10 (无应用误对焦修复): wireplumber 是设备
                 * 管理器 — 打开 V4L2 设备只为枚举/探测, 从不消费流。
                 * 之前算 reader → 枚举周期与复查窗口碰撞 → 流被误激活
                 * → 无应用时 continuous 对焦一直跑。排除。 */
                log_msg("  probe(WP): PID=%s cmd=%s", ent->d_name, cmdline);
                continue;
            }
            if (strstr(cmdline, "pipewire")) {
                /* PipeWire: portal 消费端 (Snapshot/OBS) 是真实 reader,
                 * 但也可能枚举探测 — 由调用方连续判定 (streak) 把关 */
                log_msg("  reader(PW): PID=%s cmd=%s", ent->d_name, cmdline);
                found = true;
                break;
            }
            /* 排除自己 — cmdline + exe 双保险 (writer) */
            if (is_self_router(ent->d_name)) continue;
            log_msg("  reader: PID=%s cmd=%s", ent->d_name, cmdline);
            found = true;
        }
        closedir(fddir);
    }
    closedir(dir);
    return found;
}

// ---------- watchdog (inotify 事件驱动) ----------
// IN_OPEN/IN_CLOSE 是瞬时事件, 不能直接决定激活/释放:
// - wireplumber 枚举 = 瞬时 open+close (几百 ms), 不能激活
// - PipeWire 消费端 = 持续 open (Snapshot/OBS 走 portal 时 pipewire 持 fd)
// 方案: 事件触发后延迟 CONFIRM_MS 复查 has_real_reader(), 持续打开才算 reader

static int inotify_fd = -1;
#define CONFIRM_MS 600   // 延迟复查窗口 (wireplumber 枚举 < 600ms)

static gboolean inotify_cb(GIOChannel *src, GIOCondition cond, gpointer user_data);

/* ⚠️ 2026-08-08: video16 被占用 (OBS 等 O_RDWR 打开 → S_FMT EBUSY) 时
 * 不立即退出 (避免重启抖动循环), 等 IN_CLOSE 释放后退出重启; 60s 超时兜底 */
static bool af_busy_wait = false;
static int64_t af_busy_start_ms = 0;

static gboolean confirm_reader_cb(gpointer user_data) {
    (void)user_data;
    /* ⚠️ 2026-08-10 (无应用误对焦修复): 连续判定 — 单次快照不动作,
     * 连续 3 次一致 (≈3s) 才 activate/deactivate。防 wireplumber/
     * pipewire 枚举探测 (短暂 fd) 误激活流 → 无应用时 continuous 对焦。 */
    bool has = has_real_reader();
    log_msg("复查 reader: %s (streak=%d)", has ? "有" : "无", reader_streak);
    if (has) {
        if (reader_streak < 3) reader_streak++;
    } else {
        if (reader_streak > -3) reader_streak--;
    }
    if (reader_streak >= 3 && !cam_active) {
        activate_camera();
    } else if (reader_streak <= -3 && cam_active) {
        deactivate_camera();
    }
    return G_SOURCE_REMOVE;
}

static gboolean inotify_cb(GIOChannel *src, GIOCondition cond, gpointer user_data) {
    (void)src; (void)cond; (void)user_data;
    /* ⚠️ 2026-08-09 (风暴根治): inotify 复查去抖 — af_get_trigger 每 500ms
     * popen 打开 video16 都触发 IN_OPEN/IN_CLOSE, 每次调度一个 600ms 复查
     * (扫描 /proc 全部 fd, 很慢) → 复查堆积 17.7 万次占满主循环 → Start 的
     * g_object_set 延迟 → 撞 applyControls clear 窗口 → 触发漏过。
     * 修复: 600ms 窗口内只保留一个 pending 复查, 事件风暴期间合并。 */
    static guint pending_id = 0;
    if (pending_id != 0) {
        g_source_remove(pending_id);
        pending_id = 0;
    }
    char buf[4096];
    ssize_t len;
    while ((len = read(inotify_fd, buf, sizeof(buf))) > 0) {
        for (ssize_t i = 0; i < len; ) {
            struct inotify_event *ev = (struct inotify_event *)&buf[i];
            if (ev->mask & (IN_OPEN | IN_CLOSE)) {
                /* ⚠️ 2026-08-08: busy 等待期 — video16 被占用者关闭
                 * (IN_CLOSE) → 退出重启 (3s 过滤 v4l2sink 自己的关闭) */
                if ((ev->mask & IN_CLOSE) && af_busy_wait &&
                    g_get_monotonic_time() / 1000 - af_busy_start_ms > 3000) {
                    log_msg("video16 已释放 (占用者关闭) — 退出重启恢复");
                    af_busy_wait = false;
                    fflush(logf);
                    exit(1);
                }
                // 延迟复查 (600ms, 排除 wireplumber 枚举)。
                // 系统相机 (pipewire 常驻 reader) 容忍 600ms 空窗, 实测正常。
                log_msg("IN_%s → 延迟复查 reader",
                        (ev->mask & IN_OPEN) ? "OPEN" : "CLOSE");
            }
            i += sizeof(struct inotify_event) + ev->len;
        }
    }
    /* 去抖: 事件风暴期间只调度一次复查 (覆盖式, 不堆积) */
    pending_id = g_timeout_add(CONFIRM_MS, confirm_reader_cb, NULL);
    return G_SOURCE_CONTINUE;
}

static void setup_inotify(void) {
    inotify_fd = inotify_init1(IN_NONBLOCK);
    if (inotify_fd < 0) {
        log_msg("ERROR: inotify_init1 failed: %s", strerror(errno));
        return;
    }
    int wd = inotify_add_watch(inotify_fd, SINK_DEVICE, IN_OPEN | IN_CLOSE);
    if (wd < 0) {
        log_msg("ERROR: inotify_add_watch %s failed: %s", SINK_DEVICE, strerror(errno));
        return;
    }
    GIOChannel *ch = g_io_channel_unix_new(inotify_fd);
    g_io_add_watch(ch, G_IO_IN, inotify_cb, NULL);
    g_io_channel_unref(ch);
    log_msg("inotify 监控 %s (IN_OPEN|IN_CLOSE), 事件驱动零轮询", SINK_DEVICE);
}

// ---------- GStreamer bus 监听 (灾难恢复, 2026-08-07) ----------
// 监听 ERROR/EOS → 退出 (exit 1) → systemd Restart=on-failure → ExecStartPre
// ensure-device 重建 video16 → libcamerasrc 重新初始化 → 自动恢复。
// (af_busy_wait / af_busy_start_ms 声明在 inotify_cb 前)

static gboolean af_busy_timeout_cb(gpointer user_data) {
    (void)user_data;
    log_msg("video16 占用等待 60s 超时 — 退出重启重试");
    fflush(logf);
    exit(1);
    return G_SOURCE_REMOVE;
}

static gboolean bus_cb(GstBus *bus, GstMessage *msg, gpointer user_data) {
    (void)bus; (void)user_data;
    switch (GST_MESSAGE_TYPE(msg)) {
    case GST_MESSAGE_ERROR: {
        GError *err = NULL;
        gchar *dbg = NULL;
        gst_message_parse_error(msg, &err, &dbg);
        log_msg("FATAL: pipeline 错误: %s (%s) — 退出, systemd 将重启恢复",
                err ? err->message : "?", dbg ? dbg : "?");
        /* ⚠️ 2026-08-08: S_FMT busy (video16 被 OBS 等占用, open_count>1)
         * → 等待释放 (IN_CLOSE) 再重启, 避免 13s 抖动循环 */
        if (err && strstr(err->message, "is busy")) {
            af_busy_wait = true;
            af_busy_start_ms = g_get_monotonic_time() / 1000;
            log_msg("video16 被其他进程占用 (S_FMT busy) — 等待释放后自动恢复");
            g_timeout_add(60000, af_busy_timeout_cb, NULL);
            fflush(logf);
            if (err) g_error_free(err);
            if (dbg) g_free(dbg);
            return TRUE;   /* 不退出, 等 inotify IN_CLOSE */
        }
        if (err) g_error_free(err);
        if (dbg) g_free(dbg);
        fflush(logf);
        exit(1);   // → systemd Restart=on-failure → 自动恢复
        break;
    }
    case GST_MESSAGE_EOS:
        log_msg("pipeline EOS — 退出 (正常结束)");
        exit(0);
        break;
    case GST_MESSAGE_WARNING: {
        GError *err = NULL;
        gchar *dbg = NULL;
        gst_message_parse_warning(msg, &err, &dbg);
        log_msg("警告: %s (%s)", err ? err->message : "?", dbg ? dbg : "?");
        if (err) g_error_free(err);
        if (dbg) g_free(dbg);
        break;
    }
    default:
        break;
    }
    return G_SOURCE_CONTINUE;
}

// ---------- AF 对焦转发 (2026-08-08 全新重做) ----------
// 三层链路: V4L2 控件(video16) → router 轮询转发 → libcamerasrc 属性 → IPA
//   v4l2loopback 补丁暴露 3 控件 (仅 OV5670 card_label):
//     focus_auto      0x009a090c bool   0=manual 1=auto/continuous
//     focus_absolute  0x009a090a int 0-1023  手动镜头位置
//     af_trigger      0x0098f004 int 0/1     触发一次对焦扫描
// 状态机 (router 侧):
//   continuous (默认): af-mode=2 — libcamera 内置 AF 持续评估失焦重扫
//   auto (触发锁定):   af_trigger=1 或 focus_auto 0→1 → af-mode=1 + AfTrigger
//                      自动对焦 (官方模型, 2026-08-09 定稿):
//   focus_auto=0 → AfMode=0 (manual): focus_absolute 移镜 / af_trigger 单次对焦
//   focus_auto=1 → AfMode=2 (continuous): 忽略 af_trigger/focus_absolute,
//                      切入先进失焦判断 (失焦才重扫, 不立即扫描)
//   af_trigger   → 单次对焦 (仅 manual 下有效): 临时 AfMode=1 + Start,
//                      扫描完成后回 manual (保持对焦结果)
// 无定时回退 (官方无此概念), 无心跳 (官方一次性设置; 仅保留最小
// 跨帧重发防 applyControls clear 竞争)
// 参数: 轮询 100ms, af_trigger 复位 300ms, Start 兜底重发 500ms,
//       单次对焦扫描完成回 manual 6s (粗扫+confirm+细扫+settle 上限)

#define AF_POLL_MS          100
#define AF_TRIGGER_RESET_MS 300    /* ⚠️ af_trigger 触发后延迟复位 (int 控件) */
#define AF_AUTO_RETRY_MS    500    /* ⚠️ Start 兜底重发 (防 applyControls clear 竞争) */
#define AF_SINGLE_SCAN_MS   30000  /* ⚠️ 2026-08-10: 超长兜底 (30s) — 正常
                                       完成由 af-state 轮询检测 (200ms),
                                       此定时器仅防 AfState 缺失/流停止死锁 */

/* V4L2 标准对焦控件 (videodev2.h 已定义, 无需重复) + 自定义 af_trigger */
/* ⚠️ 2026-08-09 (根因修复): 实测注册 ID = 0x0098f904 而非源码的
 * 0x0098f004 — 无条件注册版模块的 V4L2LOOPBACK_CID_BASE 是
 * V4L2_CID_USER_BASE | 0xf900 (+4=0x98f904), 与 /usr/src 0.15.4
 * 源码 (|0xf000) 不一致 (模块与源码行为不一致的又一例)。
 * 用错 ID → 进程内 G_EXT EINVAL → 被迫 popen → IN_OPEN 风暴 →
 * 主循环被复查占满 → Start 丢帧 → 触发漏过。 */
#define CID_AF_TRIGGER          0x0098f904

static int af_fd = -1;
static bool af_prop_trigger = false;   /* libcamerasrc 是否暴露 af-trigger (需 P3) */
static int af_last_focus_auto = 1;
static int af_last_focus_abs = -1;
static int af_last_trigger = 0;
static int af_cur_mode = 2;            /* 当前 af-mode 目标 (0 manual / 2 continuous) */

static int64_t af_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* ⚠️ ctrl_class 必须传 V4L2_CTRL_CLASS_* 常量 (0x00980000=USER 等) —
 * 实测: ctrl_class=0 或 V4L2_CTRL_ID2CLASS(id)(=0x0098f000) 都 EINVAL */
static int af_get_ctrl(unsigned id, unsigned cls, int *val) {
    if (af_fd < 0) return -1;
    /* ⚠️ 2026-08-09 (风暴根治): 原 G_EXT_CTRLS 用旧 40B 布局 → ENOTTY?
     * 实测内核 7.0 v4l2_ext_controls 是 32B (含 request_fd), 布局正确时
     * focus_auto/focus_abs/af_trigger 全部 G_EXT 可用 (ret=0)。
     * 统一 G_EXT: 与 af_get_trigger 一致, 不打开设备 → 无 IN_OPEN 风暴。 */
    struct v4l2_ext_control ctrl = {0};
    struct v4l2_ext_controls ctrls = {0};
    ctrl.id = id;
    ctrls.ctrl_class = cls;
    ctrls.count = 1;
    ctrls.controls = &ctrl;
    if (ioctl(af_fd, VIDIOC_G_EXT_CTRLS, &ctrls) < 0) return -1;
    *val = ctrl.value;
    return 0;
}

/* ⚠️ 2026-08-09 (风暴根治): 进程内写标准 CAMERA 类控件 (focus_auto=0 写回)。
 * S_EXT 实测可用 (ret=0) — 替代 popen v4l2-ctl, 消除 IN_OPEN 风暴。 */
static int af_set_ctrl(unsigned id, unsigned cls, int val) {
    if (af_fd < 0) return -1;
    struct v4l2_ext_control ctrl = {0};
    struct v4l2_ext_controls ctrls = {0};
    ctrl.id = id;
    ctrl.value = val;
    ctrls.ctrl_class = cls;
    ctrls.count = 1;
    ctrls.controls = &ctrl;
    if (ioctl(af_fd, VIDIOC_S_EXT_CTRLS, &ctrls) < 0) return -1;
    return 0;
}

/* ⚠️ af_trigger 读取 (2026-08-09 根因修复): 原实现 popen v4l2-ctl 子进程
 * (因用错 ID 0x0098f004 → G_EXT EINVAL)。实际注册 ID = 0x0098f904,
 * 进程内 VIDIOC_G_EXT_CTRLS 直接可用 (实测 ret=0) → 不再 popen,
 * 消除 IN_OPEN/IN_CLOSE 风暴 (曾 8.8 万事件占满主循环 → Start 丢帧)。
 * ⚠️ v4l2_ext_controls 必须用内核 7.0 布局 (32B: which/ctrl_class + count
 * + error_idx + request_fd + reserved[1] + controls*), 旧 40B 布局 ioctl
 * 会 ENOTTY。 */
static int af_get_trigger(int *val) {
    if (af_fd < 0) return -1;
    struct v4l2_ext_control ctrl = {0};
    struct v4l2_ext_controls ctrls = {0};
    ctrl.id = CID_AF_TRIGGER;
    ctrls.ctrl_class = V4L2_CTRL_CLASS_USER;
    ctrls.count = 1;
    ctrls.controls = &ctrl;
    if (ioctl(af_fd, VIDIOC_G_EXT_CTRLS, &ctrls) < 0) return -1;
    *val = ctrl.value;
    return 0;
}

/* ⚠️ 2026-08-09 (根因修复): 进程内写 af_trigger (同 G_EXT 理由, S_EXT 实测
 * ret=0)。替代 popen v4l2-ctl, 消除 IN_OPEN 风暴。 */
static int af_set_trigger(int val) {
    if (af_fd < 0) return -1;
    struct v4l2_ext_control ctrl = {0};
    struct v4l2_ext_controls ctrls = {0};
    ctrl.id = CID_AF_TRIGGER;
    ctrl.value = val;
    ctrls.ctrl_class = V4L2_CTRL_CLASS_USER;
    ctrls.count = 1;
    ctrls.controls = &ctrl;
    if (ioctl(af_fd, VIDIOC_S_EXT_CTRLS, &ctrls) < 0) return -1;
    return 0;
}

/* 主线程执行 g_object_set (GStreamer 属性设置) — 用字符串命令 */
typedef struct {
    char prop[32];
    double dval;
    int ival;
    bool is_double;
} AfPropCmd;

static gboolean af_prop_cb(gpointer data) {
    AfPropCmd *cmd = (AfPropCmd *)data;
    if (cam_src) {
        if (cmd->is_double)
            g_object_set(cam_src, cmd->prop, cmd->dval, NULL);
        else
            g_object_set(cam_src, cmd->prop, cmd->ival, NULL);
        log_msg("AF: g_object_set(%s=%s) 执行", cmd->prop,
                cmd->is_double ? "double" : "int");
    } else {
        log_msg("AF: 警告 — cam_src 为空, 属性 %s 未设置", cmd->prop);
    }
    g_free(cmd);
    return G_SOURCE_REMOVE;
}

static void af_set_src_int(const char *prop, int val) {
    AfPropCmd *cmd = g_new0(AfPropCmd, 1);
    g_strlcpy(cmd->prop, prop, sizeof(cmd->prop));
    cmd->ival = val;
    cmd->is_double = false;
    g_main_context_invoke(NULL, af_prop_cb, cmd);
}

static void af_set_src_double(const char *prop, double val) {
    AfPropCmd *cmd = g_new0(AfPropCmd, 1);
    g_strlcpy(cmd->prop, prop, sizeof(cmd->prop));
    cmd->dval = val;
    cmd->is_double = true;
    g_main_context_invoke(NULL, af_prop_cb, cmd);
}

/* 设置 af-mode (0 manual / 1 auto / 2 continuous) */
static void af_apply_mode(int mode) {
    if (mode == af_cur_mode) return;
    af_cur_mode = mode;
    af_set_src_int("af-mode", mode);
    log_msg("AF: af-mode=%d (%s)", mode,
            mode == 0 ? "manual" : mode == 1 ? "auto" : "continuous");
}

/* auto: af-trigger Start (需 P3 属性; 无则降级靠 af-mode 切换) */
static void af_apply_trigger(void) {
    if (af_prop_trigger) {
        af_set_src_int("af-trigger", 0);  /* AfTriggerStart=0 */
        log_msg("AF: af-trigger Start 已发");
    } else {
        log_msg("AF: 警告 — libcamerasrc 无 af-trigger 属性 (P3 未装), 降级: 模式抖动触发");
        af_apply_mode(2);
        af_apply_mode(1);
    }
}

/* ⚠️ 2026-08-09 (官方模型定稿): 单次对焦 Start 兜底重发 — libcamerasrc
 * applyControls 每帧 merge+clear, g_object_set 若落在 clear 窗口则丢失。
 * 保留最小重发 (1 次, 500ms 后) 防丢失; 不再 3 次跨帧重发 (官方 AfTrigger
 * 语义: 扫描中重复 Start 被忽略, 多次重发无益)。 */
static gboolean af_auto_retry_cb(gpointer user_data) {
    (void)user_data;
    af_set_src_int("af-mode", 1);
    if (af_prop_trigger)
        af_set_src_int("af-trigger", 0);
    log_msg("AF: 单次对焦 Start 兜底重发 (af-mode=1 + af-trigger)");
    return G_SOURCE_REMOVE;
}

/* ⚠️ 2026-08-09 (官方模型定稿): 单次对焦扫描完成 → 回 manual。
 * 官方语义: auto 扫描完成锁定后保持; 但我们用临时 auto 实现"单次对焦"
 * (manual 下点 af_trigger), 扫描完成后应回到 manual (focus_auto=0 意图)
 * 并保持对焦结果 (IPA manual 切入不清零, 已改)。延时 AF_SINGLE_SCAN_MS
 * 覆盖最长扫描链 (粗扫+confirm+细扫+settle)。 */
static gboolean af_single_scan_return_cb(gpointer user_data) {
    (void)user_data;
    /* ⚠️ 2026-08-10 (兜底计时取消): 兜底执行时, 若检测 timer 还在则
     * 取消 (AfState 未到达但兜底先触发, 防检测器重复回 manual) */
    if (af_state_check_timer) {
        g_source_remove(af_state_check_timer);
        af_state_check_timer = 0;
    }
    af_single_scan_timer = 0;   /* 自己执行完毕, 清除句柄 */
    af_apply_mode(0);                     /* manual */
    af_set_src_int("af-mode", 0);
    af_scanning = false;    /* ⚠️ 扫描完成, 恢复 abs 处理 */
    log_msg("AF: 单次对焦扫描完成 → 回 manual (保持对焦结果)");
    return G_SOURCE_REMOVE;
}

/* ⚠️ 2026-08-10 (AfState 完成检测): 官方 AfState 控件 — IPA 扫描状态机
 * 实时输出 (0=Idle 1=Scanning 2=Focused 3=Failed), 轮询检测扫描完成回
 * manual (替代固定定时器: 时长不确定, 定时要么中断扫描要么用户等待)。
 * 每 200ms 检查一次 (主循环线程, g_object_get 安全)。 */
#define AF_STATE_CHECK_MS   200
#define AF_STATE_IDLE       0
#define AF_STATE_SCANNING   1
#define AF_STATE_FOCUSED    2
#define AF_STATE_FAILED     3

static gboolean af_state_check_cb(gpointer user_data) {
    (void)user_data;
    if (!af_scanning) return G_SOURCE_REMOVE;   /* 已结束 */
    gint state = -1;
    if (cam_src)
        g_object_get(cam_src, "af-state", &state, NULL);
    if (state == AF_STATE_SCANNING || state < 0) {
        /* 扫描中 / 属性未读到 → 继续等 (30s 兜底定时器防死锁) */
        return G_SOURCE_CONTINUE;
    }
    /* 完成 (Focused/Idle/Failed) → 回 manual, 恢复 abs */
    /* ⚠️ 2026-08-10 (兜底计时取消): 扫描完成, 取消 30s 兜底定时器 */
    if (af_single_scan_timer) {
        g_source_remove(af_single_scan_timer);
        af_single_scan_timer = 0;
    }
    af_state_check_timer = 0;   /* 自己执行完毕, 清除句柄 */
    af_apply_mode(0);
    af_set_src_int("af-mode", 0);
    af_scanning = false;
    log_msg("AF: AfState=%d 扫描完成 → 回 manual (保持对焦结果)", state);
    return G_SOURCE_REMOVE;
}

/* ⚠️ 2026-08-09 (竞态修复): 延迟写回 af_trigger=0。
 * 立即写回 (旧实现 popen) 会与 libcamerasrc applyControls 的
 * merge+clear 跨线程竞争 — g_object_set(af-trigger=Start) 若落在
 * clear 窗口则 Start 丢失 → 触发漏过。延迟 AF_TRIGGER_RESET_MS
 * (300ms) 让 Start 兜底重发窗口完成后再复位, 保持"待触发"语义。
 * 2026-08-09 (风暴根治): 写回改用进程内 S_EXT (af_set_trigger),
 * 不再 popen 打开设备 → 无 IN_OPEN 事件。 */
static gboolean af_trigger_reset_cb(gpointer user_data) {
    (void)user_data;
    af_set_trigger(0);
    log_msg("AF: af_trigger 延迟复位为 0 (触发窗口已过)");
    return G_SOURCE_REMOVE;
}

static void *af_poll_thread(void *arg) {
    (void)arg;
    /* 轮询 fd 常开 video16 — IN_OPEN 触发, 但 has_real_reader 排除自己 */
    af_fd = open(SINK_DEVICE, O_RDWR | O_NONBLOCK);
    if (af_fd < 0) {
        log_msg("AF: 打开 %s 失败 (对焦控件不可用?) — %s", SINK_DEVICE, strerror(errno));
        return NULL;
    }
    log_msg("AF: 对焦轮询启动 (%dms), video16 fd=%d", AF_POLL_MS, af_fd);

    bool first_poll = true;   /* 首轮只初始化 last 值, 不触发 (控件持久值语义) */
    /* ⚠️ 2026-08-10 (流状态收敛修复): 定期兜底复查 reader — inotify 事件
     * 驱动复查可能丢失 (pipewire 间歇 fd 干扰/事件合并), 导致激活状态与
     * 实际不一致 (PLAYING 卡住无帧 → "画面卡住")。每 1s 兜底复查一次,
     * 状态最终收敛到真实 reader 状态。 */
    int reader_check_cnt = 0;

    while (true) {
        usleep(AF_POLL_MS * 1000);
        if (af_fd < 0) break;

        /* 定期兜底复查 (每 1s): 与 inotify 复查互补, 防事件丢失。
         * ⚠️ 2026-08-10: 连续判定 (streak) — 单次快照不动作 */
        if (++reader_check_cnt % 10 == 0) {
            bool has = has_real_reader();
            if (has) {
                if (reader_streak < 3) reader_streak++;
            } else {
                if (reader_streak > -3) reader_streak--;
            }
            if (reader_streak >= 3 && !cam_active) {
                activate_camera();
            } else if (reader_streak <= -3 && cam_active) {
                deactivate_camera();
            }
        }

        int focus_auto = -1, focus_abs = -1, trigger = -1;
        /* G_CTRL 失败 = 控件未注册 (v4l2loopback 补丁未装) → 静默跳过 */
        if (af_get_ctrl(V4L2_CID_FOCUS_AUTO, V4L2_CTRL_CLASS_CAMERA, &focus_auto) < 0) continue;
        bool have_abs = (af_get_ctrl(V4L2_CID_FOCUS_ABSOLUTE, V4L2_CTRL_CLASS_CAMERA, &focus_abs) == 0);
        /* ⚠️ 2026-08-09 (根因修复): af_trigger 用进程内 G_EXT_CTRLS 读取
         * (原 popen v4l2-ctl 子进程 — 因错 ID 0x0098f004 才被迫 popen)。
         * 实际注册 ID 0x0098f904, G_EXT 进程内可用 (实测 ret=0) →
         * 不再打开设备 → IN_OPEN 风暴消失。每 500ms 一次。 */
        bool have_trig = false;
        static int af_trig_cnt = 0;
        if (++af_trig_cnt % 5 == 0)   /* 100ms × 5 = 500ms */
            have_trig = (af_get_trigger(&trigger) == 0);

        int64_t now = af_now_ms();

        /* 首轮: 初始化 last 值 (控件可能持上次运行的设置), 不触发
         * ⚠️ 2026-08-09 (重启残留修复): af_trigger 是瞬态触发控件 —
         * 若上次运行在复位前结束 (或 continuous 下被忽略), 控件残留 1,
         * 首轮 af_last_trigger=1 → 之后设 1 无 0→1 边沿 → 永远不触发
         * (用户实测: focus_auto=0 时 af_trigger 无效)。首轮强制读 +
         * 若残留 1 则复位 0。注意 af_trig_cnt 首轮=1 不满足 %5, 必须
         * 显式读一次。 */
        if (first_poll) {
            af_last_focus_auto = focus_auto;
            af_last_focus_abs = have_abs ? focus_abs : -1;
            /* 首轮显式读 af_trigger (绕过 %5 节流) */
            af_get_trigger(&trigger);
            af_last_trigger = trigger;
            if (af_last_trigger != 0) {
                af_set_trigger(0);
                af_last_trigger = 0;
                log_msg("AF: 初始 af_trigger=%d 残留 → 强制复位 0 (瞬态控件语义)", trigger);
            }
            first_poll = false;
            log_msg("AF: 初始控件状态 focus_auto=%d focus_absolute=%d trigger=%d",
                    focus_auto, af_last_focus_abs, af_last_trigger);
            continue;
        }

        /* ═══════════ 官方模型状态机 (2026-08-09 定稿) ═══════════
         * focus_auto=0 → AfMode=0 (manual): focus_absolute 移镜 /
         *                af_trigger 单次对焦 (临时 auto+Start → 回 manual)
         * focus_auto=1 → AfMode=2 (continuous): 忽略 af_trigger/focus_absolute
         * 无定时回退, 无心跳 (仅最小 Start 兜底重发防 clear 竞争) */

        /* ① focus_auto 0→1 / 1→0 → 模式切换 */
        if (focus_auto != af_last_focus_auto) {
            if (focus_auto == 1) {
                af_apply_mode(2);                    /* continuous */
                af_set_src_int("af-mode", 2);
                log_msg("AF: continuous 模式 (focus_auto=1) — 失焦判断后重扫");
            } else {
                af_apply_mode(0);                    /* manual */
                af_set_src_int("af-mode", 0);
                log_msg("AF: manual 模式 (focus_auto=0) — 保持当前焦点");
            }
            af_last_focus_auto = focus_auto;
        }

        /* ② focus_absolute 变化 → manual 移镜 (仅 manual 模式, 官方语义:
         * continuous 下 LensPosition 忽略 — 2026-08-09 用户定稿"严格官方",
         * 必须先切 focus_auto=0 才能手动移镜)
         * ⚠️ 2026-08-10 (扫描中断修复): af_scanning 期间忽略 — 触发单次
         * 对焦后 (临时 auto 扫描中) focus_auto 控件仍是 0, 若用户拖动
         * focus_absolute 会触发 abs_event → af_apply_mode(0) 强制回 manual
         * + 发 lens-position → 打断正在进行的扫描 → 镜头停半路卡住。
         * 官方语义: auto 扫描中 LensPosition 无效, 手动干预等扫描完成。 */
        bool abs_event = (!af_scanning && focus_auto == 0 && have_abs
                          && focus_abs != af_last_focus_abs && focus_abs >= 0);
        if (abs_event) {
            af_last_focus_abs = focus_abs;
            float dioptre = focus_abs / 1023.0f * 2.0f;  /* 0-1023 → 0-2.0D */
            af_apply_mode(0);                            /* manual */
            af_set_src_int("af-mode", 0);
            af_set_src_double("lens-position", dioptre);
            log_msg("AF: manual focus_absolute=%d (%.2fD)", focus_abs, dioptre);
        } else if (have_abs && focus_abs != af_last_focus_abs && focus_abs >= 0) {
            /* continuous 下拖动: 官方语义忽略, 仅记录 last 值防误触发 */
            af_last_focus_abs = focus_abs;
            log_msg("AF: continuous 下拖动 focus_absolute=%d 忽略 (官方语义)", focus_abs);
        }

        /* ③ af_trigger 0→1 → 单次对焦 (仅 manual 下有效; continuous 忽略 —
         * 官方 V4L2 语义: AUTO_FOCUS_START 在 focus_auto=1 时无定义)
         * ⚠️ 2026-08-10 (残留修复): continuous 下 trig_event 也要复位控件
         * + af_last_trigger 保持 0 — 否则残留 1 导致切回 manual 后设 1
         * 无边沿 → 永远失效 (之前只有启动首轮处理残留, 运行中切换不处理) */
        bool trig_event = (have_trig && trigger == 1 && af_last_trigger == 0);
        if (trig_event && focus_auto == 0) {
            af_apply_mode(1);                            /* 临时 auto */
            af_apply_trigger();                          /* AfTriggerStart */
            af_set_src_int("af-mode", 1);
            /* af_trigger int 控件触发后延迟复位 (保持待触发) */
            g_timeout_add(AF_TRIGGER_RESET_MS, af_trigger_reset_cb, NULL);
            /* ⚠️ 2026-08-10 (扫描重启修复): 移除 Start 兜底重发 —
             * ENOBUFS retainControls 修复后 Start 可靠到达 IPA,
             * 重发的第二个 Start 会二次触发 IPA startAutoScan
             * (af.cpp 792-797: 每次 Start 都重启扫描) → 对焦过程
             * 被自己重发中断 (用户实测)。 */
            /* ⚠️ 2026-08-10 (AfState 完成检测): 扫描完成回 manual —
             * 200ms 轮询 af-state (官方控件), 完成即回; 30s 兜底
             * 防 AfState 缺失/流停止死锁。连续触发时先取消旧 timer
             * (防旧兜底干扰新扫描) */
            if (af_single_scan_timer) {
                g_source_remove(af_single_scan_timer);
                af_single_scan_timer = 0;
            }
            if (af_state_check_timer) {
                g_source_remove(af_state_check_timer);
                af_state_check_timer = 0;
            }
            af_state_check_timer = g_timeout_add(AF_STATE_CHECK_MS,
                                                 af_state_check_cb, NULL);
            af_single_scan_timer = g_timeout_add(AF_SINGLE_SCAN_MS,
                                                 af_single_scan_return_cb,
                                                 NULL);
            af_scanning = true;    /* ⚠️ 扫描中忽略 abs (防打断) */
            log_msg("AF: 单次对焦触发 (manual 下 af_trigger=1)");
        } else if (trig_event) {
            /* continuous: 官方语义忽略, 但复位瞬态控件 (防残留) */
            af_set_trigger(0);
            log_msg("AF: continuous 下 af_trigger 忽略 → 复位 0 (防残留)");
        }
        /* af_last_trigger 更新: continuous 忽略分支保持 0 (下次设 1 有边沿) */
        if (have_trig && !(trig_event && focus_auto != 0))
            af_last_trigger = trigger;

        /* 临时调试: 每 100 轮 (10s) 心跳, 确认轮询线程活性 + 读取值 */
        static int af_dbg_cnt = 0;
        if (++af_dbg_cnt % 100 == 0)
            log_msg("AF: poll alive (auto=%d abs=%d trig=%d)", focus_auto, focus_abs, trigger);
    }
    return NULL;
}

static void af_init(void) {
    /* 检测 libcamerasrc 是否有 af-trigger 属性 (P3 gst 补丁后才有) */
    if (cam_src) {
        GParamSpec *ps = g_object_class_find_property(
            G_OBJECT_GET_CLASS(cam_src), "af-trigger");
        af_prop_trigger = (ps != NULL);
        log_msg("AF: libcamerasrc af-trigger 属性 %s",
                af_prop_trigger ? "可用 (P3 已装)" : "缺失 (P3 未装, auto 触发降级)");
        /* 默认 continuous */
        af_apply_mode(2);
    }
    pthread_t th;
    pthread_create(&th, NULL, af_poll_thread, NULL);
}

// ---------- main ----------

int main(int argc, char **argv) {
    logf = fopen("/tmp/ov5670-router.log", "a");
    gst_init(&argc, &argv);

    if (!build_pipeline()) {
        log_msg("ERROR: build_pipeline failed");
        return 1;
    }

    // 灾难恢复: 监听 bus, ERROR/EOS → 退出 → systemd 重启 (自愈链)
    GstBus *bus = gst_element_get_bus(pipeline);
    gst_bus_add_watch(bus, bus_cb, NULL);
    gst_object_unref(bus);
    log_msg("bus 监听已启用 (ERROR → 退出重启自愈)");

    GstStateChangeReturn ret = gst_element_set_state(pipeline, GST_STATE_PLAYING);
    if (ret == GST_STATE_CHANGE_FAILURE) {
        log_msg("ERROR: pipeline PLAYING failed");
        return 1;
    }
    GstState state;
    gst_element_get_state(pipeline, &state, NULL, 10 * GST_SECOND);

    // C'': 2026-08-10 (无应用误对焦修复): 启动后停流改 READY (PAUSED 不停
    // 流 — libcamerasrc PLAYING_TO_PAUSED 不停 task → IPA 持续有帧 → 无
    // 应用时 continuous 对焦一直跑)。READY 保持 open, 未 start → IPA 无帧。
    gst_element_set_state(cam_src, GST_STATE_READY);
    log_msg("ov5670-router 启动: %s 常驻 (cam READY, 按需 activate)", SINK_DEVICE);

    af_init();   // 对焦转发 (2026-08-08): 默认 continuous + 控件轮询
    setup_inotify();
    GMainLoop *loop = g_main_loop_new(NULL, FALSE);
    log_msg("主循环启动 (inotify 事件驱动)");
    g_main_loop_run(loop);

    if (cam_active) deactivate_camera();
    gst_element_set_state(pipeline, GST_STATE_NULL);
    gst_object_unref(pipeline);
    return 0;
}
