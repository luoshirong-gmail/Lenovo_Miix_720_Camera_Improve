# OV5670 后置摄像头虚拟设备转发系统

按需将 Lenovo MIIX 720 的 OV5670 后置摄像头（IPU3 管线）转发到 v4l2loopback
虚拟设备 **/dev/video16**，为所有应用提供 **2560×1920 NV12 29fps 实时画面**，
支持自动对焦与 GPU 画质增强。

**最终状态 (2026-08-12)：写端解耦完成，相机流畅，GPU 减半，省电对焦**

## 架构（解耦写端）

```
libcamerasrc(PAUSED 常驻) → videoconvert → [GL 增强链] → appsink → write() 直写 /dev/video16
        ↑ activate: PAUSED→PLAYING   ↑ deactivate: PLAYING→PAUSED（停流保持 acquire）
```

- **写端解耦**（2026-08-12 核心改造）: 原 v4l2sink（QBUF/DQBUF 环）与
  v4l2loopback 的缓冲语义冲突（"buffer not queued" → pipewire 卡顿）。
  改为 appsink（写线程 pull）→ `write()` 直写——无缓冲环、永不阻塞、
  与读端 mmap 完全解耦。读端（pipewire/OBS）零改动。
- **PAUSED 常驻**: open/acquire/配置在 pipeline 启动时完成 → activate 只
  PAUSED→PLAYING 即出帧，不重新 open。
- **按需激活**: inotify IN_OPEN/IN_CLOSE → 复查 has_real_reader()
  （pipewire 必须 fd+mmap 才算 reader，wireplumber 枚举自动排除）→
  streak=1 立即激活（无 3s 延迟）。
- **灾难恢复**: bus ERROR/EOS → 退出 → systemd Restart=on-failure → 自愈。

## 关键文件

| 文件 | 说明 |
|---|---|
| `scripts/ov5670-router.c` | 主程序（管线 + inotify + bus 监听 + AF 桥接 + 写线程）|
| `scripts/ov5670-ensure-device.sh` | systemd ExecStartPre：确保 /dev/video16 存在 |
| `scripts/ov5670-virtual-camera.service` | systemd 用户服务 |
| `scripts/install_af.sh` | v4l2loopback AF 控件补丁安装脚本 |
| `config/51-libcamera-disable-cam6.conf` | CAM6 屏蔽规则 |
| `ipa-patches/` | IPU3 IPA 自动对焦补丁（af.cpp/af.h）|
| `gst-patches/` | GStreamer libcamerasrc AF 属性说明 |
| `tuning/` | 画质调校资产（ov5670.yaml）|
| `patched-sources/v4l2loopback/v4l2loopback.c` | 补丁后源码归档（同步 /usr/src）|

## v4l2loopback 补丁（5 个，必须全装）

| 补丁 | 位置 | 作用 | 缺失症状 |
|---|---|---|---|
| D-1 | enum_fmt | 有 writer 时只列当前格式 (NV12) | 枚举 RGB 表 → 协商 EINVAL |
| HERMES-PATCH | s_fmt | writer 活跃时 reader S_FMT 复用格式 | reader EBUSY → 打不开 |
| MIN-3 | reqbufs | writer REQBUFS ≥3 (PipeWire 下限) | "can't allocate enough buffers" |
| HERMES-PATCH-3 | start_fileio | write() 用 used_buffer_count 不撑 16 | pipewire SEGV（mmap 16）|
| HERMES-PATCH-4 | streamon | 读端 STREAMON 不 EIO | 黑屏（pipewire 无法流）|
| HERMES-PATCH-5 | start_fileio | 写端 MMAP→FILE 允许（先 REQBUFS 再 write）| write() EBUSY → 0 帧黑屏 |

> 补丁源码以 `patched-sources/v4l2loopback/v4l2loopback.c` 为权威，
> 系统 `/usr/src/v4l2loopback-0.15.4/v4l2loopback.c` 应与之 diff 一致。
> 重打流程见 `docs/UPGRADE.md`。

## 画质配置（/etc/ov5670-router.conf）

```
ENHANCE=1          # GPU 增强链（glupload→glshader→gldownload）
DENOISE_SS=0       # GPU 双边滤波关闭（硬件 BNR 承担降噪, GPU 99%→54%）
DENOISE_SR=0.25
SHARPEN=1.8        # CAS 锐化
CONTRAST=1.12
SATURATION=1.0     # 中性（关闭饱和度增强; 0=灰度, >1=增强）
VIGNETTE=1.1       # 暗角补偿（LSC 硬件不可用的替代）
CENTER_DIM=0.85
DARK_B_CORR=0.15   # 暗部去蓝
BRIGHT_B_CORR=0.05 # 亮部加蓝
CORNER_R_CORR=0.18 # 角落加红
RIPPLE=0.3         # 水波纹抑制
```

**职责划分**:
- imgU（IPA）: 中性化 —— AWB 红 0.8/蓝 1.3、CCM 单位矩阵、硬件 BNR 降噪
- GPU 链: LSC 替代（暗角）+ 艺术增强（锐化/色调）—— SHD 固件不执行 op_list，
  硬件 LSC 不可用，由 GPU 链承担

## 自动对焦

- 三模式（manual/auto/continuous）完整实现，详见 `docs/ov5670-autofocus.md`
- 控件链路: v4l2loopback AF 控件 → router 桥接 → gst 插件（ENOBUFS
  retainControls 根治，不丢控件）
- **省电对焦** (2026-08-12): 无应用时 AF 轮询 100ms→1s（cam PAUSED 无帧
  流入 IPA，continuous 重扫无意义）；有应用时恢复 100ms 全速

## 构建与运行

```bash
# ① 模块加载 (initramfs 预加载根治 — 见 docs/UPGRADE.md)
sudo cp config/ov5670-modprobe.conf /etc/modprobe.d/ov5670-virtual-camera.conf
sudo update-initramfs -u

# ② 编译 (Makefile 含 gstreamer-app-1.0 链接)
cd ~/Projects/Lenovo_Miix_720_Camera_Improve
make back_camera/scripts/ov5670-router

# ③ 配置 + 服务
sudo cp /etc/ov5670-router.conf 参考上方参数
systemctl --user daemon-reload
systemctl --user enable --now ov5670-virtual-camera.service
```

## 关键机制（踩坑摘要）

1. **PAUSED 常驻 vs READY/NULL**: READY/NULL 方案 activate 时重新 open →
   GStreamer loop 不推帧；PAUSED 常驻只开流 → 正常出帧
2. **camera-name 双转义**: gst_parse_launch 双层转义吃光 `\\` →
   parse 后 `g_object_set` 直接设置
3. **写端解耦的坑** (2026-08-12):
   - write() 首次调用 start_fileio 用 max_buffers(16) 撑缓冲 → pipewire mmap 16
     SEGV → PATCH-3 用 used_buffer_count + writer_open 先 REQBUFS(3)
   - keep_format=1 锁死重启后默认格式 BGR4 → 移除（PATCH-4 正本清源修 EIO）
   - 写端先 REQBUFS(3) 后 write() 被 io_method 检查拒 → PATCH-5 允许 MMAP→FILE
   - appsink 信号回调 + pull 混用丢 sample → 独立写线程 try_pull_sample
4. **双流 viewfinder 是负优化** (2026-08-12 实测回退): libcamerasrc 双流
   (main+viewfinder) 帧率大跌（ImgU 双流调度开销 > AF 收益），已回退单流
5. **reader > writer buffer → SEGV**: 共享缓冲，reader 超 writer 越界崩溃

## 摄像头上下文

- OV5670 camera ID: `\_SB_.PCI0.I2C2.CAM6`
- VCM: dw9719 @ `/sys/bus/i2c/devices/i2c-INT3479:00-VCM`
- `/dev/video16`: 动态创建（ensure-device.sh，`-x 0`）
- `/dev/video99`: 前置增强占用（camera-enhancement.service），互不干扰
- v4l2loopback 参数: `exclusive_caps=0 max_width=3840 max_height=2160 max_buffers=16`

## 验证结果（2026-08-12 最终）

- ✅ 系统相机 (Snapshot) 流畅（写端解耦后，27fps）
- ✅ GPU 54%（DENOISE_SS=0，硬件 BNR 降噪）
- ✅ AF 首次打开即对焦（continuous 正常）
- ✅ 无应用时省电（AF 轮询降频 + cam PAUSED 双停）
- ✅ pipewire 无 SEGV（PATCH-3 缓冲数固定）
- ✅ 灾难恢复（kill -9 实测自动重启）
