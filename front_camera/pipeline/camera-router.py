#!/usr/bin/python3
# -*- coding: utf-8 -*-
"""camera-router.py — Python 版动态增强虚拟摄像头 (前摄 video99)

架构 (2026-08-08, 基于 exp_actpad.py 验证成功结构):
  idle 链 (常驻): videotestsrc(pattern=2 黑) → capsfilter → queue → capsfilter
                  → selector sink_0 → v4l2sink(/dev/video99)
  增强链 (动态):  v4l2src(/dev/video14) → jpegdec → glupload → glcolorconvert
                  → glshader → glcolorconvert → gldownload → queue → capsfilter
                  → selector sink_1

切换: inotify 监听 video99 IN_OPEN/IN_CLOSE → 激活/停用增强链 → 700ms 后
      selector 切 active-pad (等首帧积压)。停用时增强链整体拆除, video14
      完全释放 → 用户可自由选择物理前摄。

背景: C 版 (camera-router.c) 动态激活增强链 7 个变体全部失败 (video14 只
      DQBUF 1 帧, GL context 竞态); Python gi 复现同逻辑全部成功 (124+ buffer
      满速)。改用 Python 实现切换模块 (inotify 事件驱动, 无轮询)。
"""
import gi, os, sys, time, signal, ctypes, struct

gi.require_version('Gst', '1.0')
from gi.repository import Gst, GLib

Gst.init(None)

# ---------- 配置 ----------
# ⚠️ 2026-08-10: UVC 节点号开机漂移 (video14 → video11 等), 写死节点号
# 会读到错误设备 (ipu3-imgu)。自动探测: 优先稳定符号链接 (USB ID), 扫描兜底。
def _find_src_device():
    byid = '/dev/v4l/by-id/usb-Chicony_Electronics_Co._Ltd._EasyCamera_0001-video-index0'
    if os.path.exists(byid):
        return byid
    import fcntl, struct
    for n in range(64):
        path = f'/dev/video{n}'
        try:
            fd = os.open(path, os.O_RDWR)
        except OSError:
            continue
        try:
            buf = bytearray(104)
            fcntl.ioctl(fd, 0x80685600, buf)  # VIDIOC_QUERYCAP (_IOR 'V' 0)
            driver = bytes(buf[0:16]).split(b'\x00')[0].decode()
            card = bytes(buf[16:48]).split(b'\x00')[0].decode()  # card @ offset 16
            if driver == 'uvcvideo' and 'EasyCamera' in card:
                return path
        except OSError:
            pass
        finally:
            os.close(fd)
    return '/dev/video14'  # 兜底 (旧环境)

SRC_DEVICE = _find_src_device()  # 物理前摄 (自动探测, 防漂移)
SINK_DEVICE = '/dev/video99'     # 虚拟输出 (EnhancedCamera)
# ⚠️ 2026-08-10 (发布净化): shader 路径运行时推导 (__file__ 上溯 1 级 = front_camera)
FRAG_PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                         'shaders', 'enhance.frag')
SWITCH_DELAY_MS = 700            # 激活后延迟切换 active-pad (等首帧积压)
SRC_W, SRC_H, FPS = 1280, 720, 30

CAPS_FULL = Gst.Caps.from_string(
    'video/x-raw, width=(int)1920, height=(int)1080, format=(string)NV12, '
    'framerate=(fraction)30/1, multiview-mode=(string)mono, '
    'multiview-flags=(GstVideoMultiviewFlagsSet)0, '
    'pixel-aspect-ratio=(fraction)1/1, interlace-mode=(string)progressive, '
    'colorimetry=(string)bt601')
# ⚠️ colorimetry=bt601: v4l2loopback (video99) 当前格式 colorspace=SMPTE170M
# (bt601), 重启后 pipewire 真实消费端打开时, 增强链切换触发 v4l2sink 重设
# 格式 — jpegdec 注入的 colorimetry(2:4:7:1) 被设备拒绝 → FATAL 退出。
# 显式 bt601: ① 与设备兼容 ② idle/增强两条链 caps 完全一致 → 切换零重建
# (1a01d07 目标)。GL 链协商会自动做色域转换 (glcolorconvert 支持)。
CAPS_JPEG = Gst.Caps.from_string(
    f'image/jpeg, width=(int){SRC_W}, height=(int){SRC_H}, framerate=(fraction){FPS}/1')

# ---------- inotify (ctypes, 无第三方依赖) ----------
IN_OPEN = 0x20
IN_CLOSE = 0x18  # IN_CLOSE_WRITE | IN_CLOSE_NOWRITE

_libc = ctypes.CDLL(None, use_errno=True)
_inotify_init1 = _libc.inotify_init1
_inotify_init1.restype = ctypes.c_int
_inotify_add_watch = _libc.inotify_add_watch
_inotify_add_watch.restype = ctypes.c_int
_inotify_rm_watch = _libc.inotify_rm_watch

_inotify_fd = _inotify_init1(0)
if _inotify_fd < 0:
    sys.stderr.write('ERROR: inotify_init1 failed\n')
    sys.exit(1)

# ---------- 全局 ----------
pipe = None
selector = None
idle_pad = None
enhance_pad = None
enh = []              # 增强链元素 (激活时创建)
enhance_active = False
switch_timer_id = None


def log(msg):
    print(f'[{time.strftime("%H:%M:%S")}] {msg}', flush=True)


def mk(factory, name):
    e = Gst.ElementFactory.make(factory, name)
    if not e:
        log(f'ERROR: 无法创建元素 {factory}')
        sys.exit(1)
    return e


# ---------- reader 检测 (直接扫 /proc, 与 C 版一致) ----------
def has_real_reader():
    """扫描 /proc/*/fd: 是否有真实 reader 进程持有 SINK_DEVICE fd。
    - 排除所有含 'camera-router' 的进程 (自己 + 旧实例)
    - 持有 fd 的进程必须同时有 mmap (/proc/PID/maps 含 SINK_DEVICE) 才算
      真实 reader — pipewire/wireplumber 对"有 writer 的 v4l2 设备"常驻
      监控持有 (只 open 不消费, 无 mmap), 不算 reader; portal 消费时
      pipewire 会 mmap+streaming (有 mmap) → 保留 3beada9 语义。
      (2026-08-08 实测: pipewire 监控 video99 无 mmap, v4l2sink 有 3 个
       mmap 区域)"""
    for pid in os.listdir('/proc'):
        if not pid.isdigit():
            continue
        try:
            with open(f'/proc/{pid}/cmdline', 'rb') as f:
                cmd = f.read().replace(b'\0', b' ').decode(errors='replace')
        except OSError:
            continue
        if 'camera-router' in cmd:
            continue  # router 自己/旧实例, 非 reader
        fdpath = f'/proc/{pid}/fd'
        try:
            fds = os.listdir(fdpath)
        except OSError:
            continue
        for fd in fds:
            try:
                target = os.readlink(f'{fdpath}/{fd}')
            except OSError:
                continue
            if SINK_DEVICE in target:
                # 关键: 必须 mmap (消费) 才算 reader — 监控持有 (pipewire)
                # 只 open 不 mmap, 不消费数据
                try:
                    with open(f'/proc/{pid}/maps', 'r') as mf:
                        maps = mf.read()
                except OSError:
                    continue
                if SINK_DEVICE in maps:
                    log(f'  reader 检测: PID={pid} cmd={cmd.strip()} (消费中: mmap)')
                    return True
                # 持有 fd 但无 mmap = 监控/枚举持有, 非消费 reader
    return False


# ---------- 增强链激活/停用 ----------
def build_enhance():
    """创建增强链 9 元素并接入 pipeline (全部 PLAYING)。"""
    global enhance_pad
    try:
        frag = open(FRAG_PATH).read()
    except OSError:
        log(f'ERROR: 无法读取 shader {FRAG_PATH}')
        return False

    src = mk('v4l2src', 's')
    src.set_property('device', SRC_DEVICE)
    src.set_property('do-timestamp', True)
    jd = mk('jpegdec', 'j')
    u = mk('glupload', 'u')
    e0 = mk('glcolorconvert', 'e0')
    sh = mk('glshader', 'sh')
    sh.set_property('fragment', frag)
    e1 = mk('glcolorconvert', 'e1')
    dl = mk('gldownload', 'dl')
    q = mk('queue', 'q')
    q.set_property('max-size-buffers', 4)   # 下限 4: PipeWire 要 ≥3 (b9a33d8 修复)
    q.set_property('leaky', 2)
    cf = mk('capsfilter', 'cf')
    cf.set_property('caps', CAPS_FULL)      # 与 idle 链完全一致 → 切换零重建
    enh.extend([src, jd, u, e0, sh, e1, dl, q, cf])

    for e in enh:
        pipe.add(e)

    if not src.link_filtered(jd, CAPS_JPEG):
        log('ERROR: v4l2src->jpegdec link 失败')
        return False
    for a, b in ((jd, u), (u, e0), (e0, sh), (sh, e1), (e1, dl), (dl, q), (q, cf)):
        if not a.link(b):
            log(f'ERROR: {a.get_name()}->{b.get_name()} link 失败')
            return False

    enhance_pad = selector.request_pad_simple('sink_%u')
    if not enhance_pad:
        log('ERROR: selector sink_1 request 失败')
        return False
    if cf.get_static_pad('src').link(enhance_pad) != Gst.PadLinkReturn.OK:
        log('ERROR: cf->selector link 失败')
        return False

    # 全部 sync 到 PLAYING (Python gi 时序已验证安全 — GIL 串行化)
    for e in enh:
        e.sync_state_with_parent()
    return True


def teardown_enhance():
    """拆除增强链, video14 完全释放。"""
    global enhance_pad
    if enhance_pad:
        try:
            selector.release_request_pad(enhance_pad)
        except Exception:
            pass
        enhance_pad = None
    for e in reversed(enh):
        try:
            e.set_state(Gst.State.NULL)
        except Exception:
            pass
        try:
            pipe.remove(e)
        except Exception:
            pass
    enh.clear()


def activate_enhance():
    global enhance_active, switch_timer_id
    if enhance_active:
        return
    log('检测到 OPEN → 激活增强')
    if not build_enhance():
        log('ERROR: 增强链构建失败')
        teardown_enhance()
        return
    enhance_active = True
    if switch_timer_id is not None:
        GLib.source_remove(switch_timer_id)
    # 延迟切换: 等增强链首帧积压后再切, 切换瞬间即有帧
    switch_timer_id = GLib.timeout_add(SWITCH_DELAY_MS, switch_to_enhance_cb)
    log(f'增强已激活 (video14 打开, 9 元素, {SWITCH_DELAY_MS}ms 后切换)')


def deactivate_enhance():
    global enhance_active, switch_timer_id
    if not enhance_active:
        return
    if switch_timer_id is not None:
        GLib.source_remove(switch_timer_id)
        switch_timer_id = None
    # 先切回静态帧
    selector.set_property('active-pad', idle_pad)
    time.sleep(0.2)
    teardown_enhance()
    enhance_active = False
    log('增强已停用 (video14 释放, 物理前摄可用)')


def switch_to_enhance_cb():
    global switch_timer_id
    if enhance_active and enhance_pad:
        selector.set_property('active-pad', enhance_pad)
        log(f'切换 active-pad → 增强链 (延迟 {SWITCH_DELAY_MS}ms)')
    switch_timer_id = None
    return GLib.SOURCE_REMOVE


# ---------- inotify 事件回调 (主线程 GMainLoop) ----------
def inotify_cb(channel, condition, user_data=None):
    """GLib io watch 回调: 签名 (channel, condition, user_data)。"""
    try:
        data = os.read(_inotify_fd, 4096)
    except OSError:
        return True
    off = 0
    while off + struct.calcsize('iIII') <= len(data):
        wd, mask, cookie, name_len = struct.unpack_from('iIII', data, off)
        off += struct.calcsize('iIII') + name_len
        if mask & IN_OPEN:
            log('检测到 OPEN → 激活增强')
            activate_enhance()
        elif mask & IN_CLOSE:
            log('检测到 CLOSE → 检查 reader')
            if not has_real_reader():
                deactivate_enhance()
    return True


# ---------- 信号/退出 ----------
def cleanup(signum=None, frame=None):
    log('退出中...')
    deactivate_enhance()
    if pipe:
        pipe.set_state(Gst.State.NULL)
    _inotify_rm_watch(_inotify_fd, 0)
    os.close(_inotify_fd)
    sys.exit(0)


def bus_error_cb(bus, msg):
    if msg.type == Gst.MessageType.ERROR:
        err, dbg = msg.parse_error()
        log(f'FATAL: pipeline 错误: {err.message} ({dbg}) — 退出, systemd 将重启')
        # ⚠️ 2026-08-08: 退出码必须非零 — Restart=on-failure 只对非零退出重启!
        # (之前 exit(0) → 服务死了不重启 → 重启后增强版打不开的根因之一)
        os._exit(1)


# ---------- main ----------
def main():
    global pipe, selector, idle_pad
    log(f'camera-router.py 启动 (Python 版, {SRC_DEVICE} → {SINK_DEVICE})')

    pipe = Gst.Pipeline.new('camera-router-py')

    # idle 链 (常驻)
    idle = mk('videotestsrc', 'idle_src')
    idle.set_property('pattern', 2)
    idle.set_property('is-live', True)
    idle.set_property('do-timestamp', True)
    ic = mk('capsfilter', 'ic')
    ic.set_property('caps', CAPS_FULL)
    q0 = mk('queue', 'q0')
    io = mk('capsfilter', 'io')
    io.set_property('caps', CAPS_FULL)
    selector = mk('input-selector', 'sel')
    selector.set_property('sync-streams', True)
    sk = mk('v4l2sink', 'sk')
    sk.set_property('device', SINK_DEVICE)
    sk.set_property('sync', False)

    for e in (idle, ic, q0, io, selector, sk):
        pipe.add(e)
    for a, b in ((idle, ic), (ic, q0), (q0, io)):
        if not a.link(b):
            log(f'ERROR: idle link {a.get_name()}->{b.get_name()} 失败')
            sys.exit(1)
    if not selector.link_filtered(sk, CAPS_FULL):
        log('ERROR: selector->sink link 失败')
        sys.exit(1)
    idle_pad = selector.request_pad_simple('sink_%u')
    if io.get_static_pad('src').link(idle_pad) != Gst.PadLinkReturn.OK:
        log('ERROR: io->selector link 失败')
        sys.exit(1)
    log('idle 链构建完成')

    # bus 错误监控 (systemd 重启恢复)
    bus = pipe.get_bus()
    bus.add_signal_watch()
    bus.connect('message', bus_error_cb)

    # 启动
    ret = pipe.set_state(Gst.State.PLAYING)
    if ret == Gst.StateChangeReturn.FAILURE:
        log('ERROR: pipeline PLAYING 失败 (video99 被占用?)')
        sys.exit(1)
    # 等 pipeline 稳定, 再设置初始 active-pad = idle (PLAYING 前设置会 double free)
    time.sleep(2.5)
    selector.set_property('active-pad', idle_pad)
    log(f'camera-router 启动: {SINK_DEVICE} 常驻 writer (静态帧)')

    # inotify 监控 video99 (GLib io watch, 主线程)
    wd = _inotify_add_watch(_inotify_fd, SINK_DEVICE.encode(), IN_OPEN | IN_CLOSE)
    if wd < 0:
        log(f'ERROR: inotify_add_watch 失败: {os.strerror(ctypes.get_errno())}')
        sys.exit(1)
    log(f'监控启动: inotify 监听 {SINK_DEVICE}')

    GLib.io_add_watch(_inotify_fd, GLib.IO_IN, inotify_cb)
    signal.signal(signal.SIGTERM, cleanup)
    signal.signal(signal.SIGINT, cleanup)

    log('主循环运行中 (Ctrl+C 退出)')
    GLib.MainLoop().run()


if __name__ == '__main__':
    main()
