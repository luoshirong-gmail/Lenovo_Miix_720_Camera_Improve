# Lenovo MIIX 720 Camera Improve

Lenovo MIIX 720-12IKB (80VV) 摄像头功能提升项目（合并版）。

> **前提**: 本项目的所有功能提升建立在**主板硬件驱动正常**的基础上。
> 底层硬件驱动（TPS68470 电源管理、OV5670 sensor 驱动、dw9719 对焦、ipu3-cio2、
> mc-device ancillary link 等内核补丁）由**另一独立项目**（Lenovo_Miix_720_ov5670_driver）维护，
> 本项目的补丁仅限 **v4l2loopback 虚拟摄像头层**（功能提升层），不涉及硬件驱动修改。

## 项目组成

| 模块 | 功能 | 位置 |
|---|---|---|
| 前置 RGB 增强 | EasyCamera → GL 增强 → video99 (1080p NV12) | `front_camera/` |
| 后置 OV5670 虚拟摄像头 | CAM6 (IPU3) → 解耦写端 → video16 (2560×1920 NV12) | `back_camera/` |
| 共享组件 | v4l2loopback 补丁链 / modprobe 配置 / wireplumber 刷新 | `common/` |

两个虚拟设备共用同一 v4l2loopback 内核模块（0.15.4，5 个 HERMES 补丁），
`video_nr=99` 归前置；video16 由 `v4l2loopback-ctl add` 动态创建。

**不包含**: IR 摄像头项目、内核硬件驱动补丁（归 ov5670_driver 项目）。
**发布**: 本项目已发布到 GitHub（GPL-3.0）。

## 架构总览

```
┌─ front_camera (前置 RGB 增强) ─────────────────────────────┐
│ EasyCamera /dev/video14 (MJPG 720p)                        │
│   └─ camera-router (GL shader: DENOISE/SHARPEN/GAMMA/SAT)  │
│        └─ EnhancedCamera /dev/video99 (NV12 1080p)         │
│   systemd: camera-enhancement.service                      │
└────────────────────────────────────────────────────────────┘
┌─ back_camera (后置 OV5670 虚拟摄像头) ─────────────────────┐
│ CAM6 (IPU3, libcamera)                                     │
│   └─ ov5670-router (C' 架构: PAUSED 常驻, 按需激活)        │
│        libcamerasrc → videoconvert → GL 增强链             │
│          → appsink → write() 直写 (解耦写端)               │
│        └─ OV5670 Back Camera /dev/video16 (NV12 2560×1920) │
│   systemd: ov5670-virtual-camera.service                   │
└────────────────────────────────────────────────────────────┘
┌─ common (共享组件) ────────────────────────────────────────┐
│ v4l2loopback-patches/apply_all.py  统一补丁链 (幂等)        │
│ config/                              统一 modprobe.d/加载   │
│ wireplumber-refresh.sh              参数化枚举修复          │
└────────────────────────────────────────────────────────────┘
```

## 后置摄像头架构（2026-08-12 最终形态）

**写端解耦**（解决 pipewire 卡顿的根因——v4l2loopback QBUF/DQBUF 环与
GStreamer 语义冲突 "buffer not queued"）：

```
libcamerasrc (PAUSED 常驻, 按需激活)
→ videoconvert → NV12 2560×1920
→ GL 增强链 (ENHANCE=1): glupload → glcolorconvert → glshader → gldownload
→ appsink (写线程 pull) → write() 直写 /dev/video16
```

- **写端**: appsink 回调 → `write()` 直写（无 QBUF/DQBUF 环，与读端 mmap 完全解耦）
- **读端**: pipewire/OBS mmap 读取（零改动）
- **v4l2loopback 补丁**（5 个，`common/v4l2loopback-patches/`）:
  | 补丁 | 作用 |
  |---|---|
  | D-1 | ENUM_FMT 只列 writer 格式 (NV12) |
  | HERMES-PATCH | writer 活跃时 reader S_FMT 复用格式 |
  | MIN-3 | writer REQBUFS ≥3 (PipeWire 下限) |
  | HERMES-PATCH-3 | write() 用 used_buffer_count (防撑 16 → pipewire SEGV) |
  | HERMES-PATCH-4/5 | 读端 STREAMON 不 EIO / 写端 MMAP→FILE 允许 |

- **激活机制**: inotify IN_OPEN/IN_CLOSE → 复查 has_real_reader()（pipewire 必须
  fd+mmap 才算 reader，wireplumber 枚举自动排除）→ 立即激活（streak=1）

## 画质与对焦（2026-08-12 定稿）

- **imgU（IPA）**: 中性化 —— AWB 红 0.8/蓝 1.3、CCM 单位矩阵、硬件 BNR 降噪
- **GPU 链**: LSC 替代（暗角 VIGNETTE）+ 艺术增强（CAS 锐化/色调）
  - `DENOISE_SS=0`（GPU 双边滤波关闭——硬件 BNR 已承担降噪，GPU 99%→54%）
  - 其余定稿: `SHARPEN=1.8 CONTRAST=1.12 SATURATION=1.0(中性) VIGNETTE=1.1`
- **自动对焦**: 三模式（manual/auto/continuous）完整实现，AF 控件链路
  v4l2loopback → router 桥接 → gst 插件（ENOBUFS retainControls 根治）
- **省电对焦**: 无应用时 AF 轮询 100ms→1s（cam PAUSED 双停流，CPU 空闲减 ~90%）

## 快速上手

```bash
systemctl --user status camera-enhancement.service      # 前置增强
systemctl --user status ov5670-virtual-camera.service   # 后置虚拟摄像头
systemctl --user restart ov5670-virtual-camera.service
```

### 后置摄像头配置（/etc/ov5670-router.conf）

```
ENHANCE=1 DENOISE_SS=0 SHARPEN=1.8 CONTRAST=1.12 SATURATION=1.0
VIGNETTE=1.1 CENTER_DIM=0.85 DARK_B_CORR=0.15 BRIGHT_B_CORR=0.05
CORNER_R_CORR=0.18 RIPPLE=0.3
```

### 补丁重打（内核升级 / 模块重装后）

```bash
python3 common/v4l2loopback-patches/apply_all.py --check   # 只读检查
sudo python3 common/v4l2loopback-patches/apply_all.py      # 应用缺失补丁
# 完整流程见 docs/UPGRADE.md
```

## 验证命令

```bash
v4l2-ctl --list-devices
# 后置虚拟出流 (video16)
v4l2-ctl -d /dev/video16 --get-fmt-video
# 枚举格式只 NV12 (D-1 生效)
v4l2-ctl -d /dev/video16 --list-formats
# PipeWire 节点
pw-dump | grep -A2 'Video/Source'
```

## 兼容性说明

- 腾讯会议只枚举 /dev/video0-15 — video16 可见但分辨率超 720p 上限黑屏（已放弃）
- 系统相机 (Snapshot) 直连 CAM6 仅 720p — 走 video16 获得 2560×1920
- 前置 EasyCamera 通过 libcamera monitor 枚举时会短暂亮起（UVC 上电，正常现象）
