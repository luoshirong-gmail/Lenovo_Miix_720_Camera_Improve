# Lenovo MIIX 720 Camera Improve

Lenovo MIIX 720-12IKB (80VV) 摄像头功能提升项目（合并版）。

> **前提**: 本项目的所有功能提升建立在**主板硬件驱动正常**的基础上。
> 底层硬件驱动（TPS68470 电源管理、OV5670 sensor 驱动、dw9719 对焦、ipu3-cio2、
> mc-device ancillary link 等内核补丁）由**另一独立项目**（本型号电脑主板硬件驱动项目）维护，
> 本项目的补丁仅限 **v4l2loopback 虚拟摄像头层**（功能提升层），不涉及内核模块源码的硬件驱动修改。

## 项目背景 (2026-08-08 合并)

由两个独立项目合并而来（原目录保留只读作为历史备份存档）：

| 原项目 | 会话 | 功能 | 本项目中位置 |
|---|---|---|---|
| `USB_Camera_Enhancement` | 20260805_230625_26d388 | 前置 RGB 摄像头 GL 增强 | `front_camera/` |
| `Lenovo_Miix_720_Camera/ov5670_universalization` | 20260806_154617_97ac43 | 后置 OV5670 虚拟摄像头 | `back_camera/` |

合并目标：两项目共享 v4l2loopback 内核模块与系统配置（modprobe.d / modules-load.d /
wireplumber 刷新机制），分项目维护易漏补丁、易配置冲突。合并后统一在
`common/` 维护共享组件，两个摄像头功能作为两个独立 systemd 服务分别开发升级。

**不包含**: IR 摄像头项目、ov5670 对焦功能项目（已回滚）、内核硬件驱动补丁（归硬件项目）。
**发布**: 本项目已发布到 GitHub（GPL-3.0），欢迎参考与二次开发。补丁仅限
v4l2loopback 虚拟摄像头层 + 用户态（router/gst 插件/IPA），系统部署涉及
用户特定路径（systemd 服务用 `%h` 转义、脚本用 `$PROJECT_ROOT` 推导）。

## 版本控制策略（git 跟踪 vs 磁盘文件）

**磁盘上存在但未被 git 跟踪的文件**均为"不入库"类别，忽略规则
（`.gitignore`，含各子目录）持续有效——以下文件**从未被提交**（`git log --all`
验证，勿用 `git add -f` 强制加入，重编译后 `git status` 也不会显示它们）：

| 类别 | 文件 | 不入库原因 |
|---|---|---|
| 编译产物 | `back_camera/scripts/ov5670-router`、`front_camera/pipeline/camera-router` | 源码为准（`gcc -O2 -Wall -o ...`，见各 README） |
| 构建源码包 | `back_camera/build-sources/*.tar.gz` | 大文件（39MB），本地保留供比对排查 |
| 回滚备份 | `*.bak`（含 `back_camera/backups/*.bak-*`、`docs/rollback-20260808-*/*.bak`） | 大文件/备份，磁盘保留供回滚（2026-08-09 起统一不入库，历史已跟踪的已 `git rm --cached`） |
| 原始数据 | `docs/archive/*.bin` | 抓帧原始数据（7.3MB），分析脚本 `.c` 已入库 |
| Python 缓存 | `__pycache__/`、`*.pyc` | 生成物 |

> 若未来确有文件需要入库（如小体积样本），先 `git add -f` 并同步更新 `.gitignore` 移除对应规则，
> 避免"已跟踪文件 + 忽略规则"的混淆状态（gitignore 对已跟踪文件无效）。

## 架构总览

```
┌─ front_camera (前置 RGB 增强) ─────────────────────────────┐
│ EasyCamera /dev/video14 (MJPG 720p)                        │
│   └─ camera-router (GL shader: DENOISE/SHARPEN/GAMMA/SAT)  │
│        └─ EnhancedCamera /dev/video99 (NV12 1080p)         │
│   systemd: camera-enhancement.service                      │
└────────────────────────────────────────────────────────────┘
┌─ back_camera (后置 OV5670 虚拟摄像头) ─────────────────────┐
│ CAM6 (IPU3 管线, libcamera)                                │
│   └─ ov5670-router (C' 架构: PAUSED 常驻, 按需激活)        │
│        └─ OV5670 Back Camera /dev/video16 (NV12 2560×1920) │
│   systemd: ov5670-virtual-camera.service                   │
└────────────────────────────────────────────────────────────┘
┌─ common (共享组件) ────────────────────────────────────────┐
│ v4l2loopback-patches/apply_all.py  统一补丁链 (幂等)        │
│ config/                              统一 modprobe.d/加载   │
│ wireplumber-refresh.sh              参数化枚举修复          │
└────────────────────────────────────────────────────────────┘
```

两个虚拟设备共用同一 v4l2loopback 内核模块（0.15.4），
参数 `exclusive_caps=0 max_width=3840 max_height=2160 max_buffers=16`，
`video_nr=99 card_label=EnhancedCamera` 归前置；video16 由 `v4l2loopback-ctl add` 动态创建。

## 目录结构

```
Lenovo_Miix_720_Camera_Improve/
├── README.md                 # 本文件
├── LICENSE                   # GPL-3.0
├── docs/                     # 架构决策、合并记录、踩坑、升级手册
│   ├── pre-merge-baseline.md # 合并前系统基线 (P0)
│   ├── merge-record.md       # 合并过程记录
│   └── UPGRADE.md            # 内核升级/补丁重打流程
├── common/                   # ★ 共享组件
│   ├── v4l2loopback-patches/ # 统一补丁链 apply_all.py (+ 历史脚本归档)
│   ├── config/               # modprobe.d / modules-load.d 统一 conf, ec-fix
│   └── wireplumber-refresh.sh
├── front_camera/             # ★ 前置 RGB 增强 (原 USB_Camera_Enhancement)
│   ├── pipeline/camera-router.c (+ 二进制)
│   ├── shaders/enhance.frag
│   ├── scripts/              # service + 构建/安装
│   └── config/               # EasyCamera 屏蔽规则
└── back_camera/              # ★ 后置 OV5670 (原 ov5670_universalization)
    ├── scripts/              # ov5670-router.c + ensure-device + service + install_af.sh
    ├── config/               # 51-CAM6 屏蔽规则
    ├── ipa-patches/          # IPU3 IPA 自动对焦补丁 (af.cpp/af.h)
    ├── gst-patches/          # GStreamer libcamerasrc AF 属性说明
    └── tuning/               # 画质调校 (ov5670.yaml + Intel 官方 AIQ 调校)
```

## 快速上手

### 服务管理（两个独立服务）

```bash
systemctl --user status camera-enhancement.service      # 前置增强
systemctl --user status ov5670-virtual-camera.service   # 后置虚拟摄像头
systemctl --user restart camera-enhancement.service
systemctl --user restart ov5670-virtual-camera.service
```

### 补丁重打（内核升级 / v4l2loopback 模块重装后）

```bash
# 检查补丁状态 (只读)
python3 common/v4l2loopback-patches/apply_all.py --check
# 应用缺失补丁 (需 root)
sudo python3 common/v4l2loopback-patches/apply_all.py
# 然后编译/签名/安装 — 完整流程见 docs/UPGRADE.md
```

## 后置自动对焦与画质（2026-08-08）

- **自动对焦**：OV5670 (IPU3) 三模式对焦完整修复（触发可靠性跨帧重发、
  失焦判定归一化方差/自适应基准/连续确认、auto 扫描精度细扫固定轨迹、
  40s 锁定窗口），详见 `docs/ov5670-autofocus.md` 与
  `back_camera/ipa-patches/`。
- **画质调校**：`back_camera/tuning/ov5670.yaml`（AGC 目标亮度 0.35，
  实测亮度提亮 3 倍）；Intel 官方 ov5670 AIQ 调校（Apache 2.0）已归档
  供后续完整 3A 调校。

## 验证命令

```bash
# 设备列表
v4l2-ctl --list-devices
# 前置增强出流 (video99)
v4l2-ctl -d /dev/video99 --set-fmt-video=width=1920,height=1080,pixelformat=NV12 \
  --stream-mmap --stream-count=5 --stream-to=/dev/null
# 后置虚拟出流 (video16)
v4l2-ctl -d /dev/video16 --get-fmt-video
# PipeWire 节点
pw-dump | grep -A2 'Video/Source'
```

## 兼容性说明

- 腾讯会议只枚举 /dev/video0-15 连续段 — video16 是段内最近空槽（可枚举但选择黑屏
  因分辨率超 720p 上限，已放弃）
- 系统相机 (Snapshot) 直连 CAM6 仅 720p (libcamera 0.7 kViewfinderSize) — 走 video16
  可获得 2560×1920
- 前置 EasyCamera 通过 libcamera monitor 枚举时会短暂亮起 (UVC 上电, 正常现象)
