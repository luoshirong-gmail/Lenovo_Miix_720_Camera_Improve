# USB Camera Enhancement Pipeline

通过 **Intel HD 620 核显 (iGPU)** 对 USB 摄像头画面进行实时画质增强（降噪/锐化/色彩）并超分，
输出为虚拟摄像头设备供任意应用使用（OBS、系统相机、Zoom、Telegram…）。

> 在 Lenovo Miix 720 (i5-7200U / HD 620 / Ubuntu 26.04) 上开发验证。
> 适用于任何支持 V4L2 的 USB 摄像头 + 任意带 GPU 的 Linux 主机。

## 特性

- 🎨 **GPU 实时画质增强**：5×5 降噪、自适应 unsharp 锐化、gamma 提亮、对比度/饱和度增强 — 全部在 iGPU fragment shader 内完成，CPU 零计算（仅 JPEG 解码）
- 🔍 **Bicubic 超分**：720p → 1080p Catmull-Rom 4×4 插值（比 GPU 默认双线性更锐利），可用 `UPSCALE` 开关关闭
- 🔌 **虚拟摄像头**：v4l2loopback → `/dev/video99` (EnhancedCamera)，任意应用即选即用
- ⚡ **按需启停**：有应用读取时激活增强链，无读取者时自动释放原始摄像头（原始前置镜头可随时切换使用）
- 🌙 **低光友好**：gamma 提亮暗部，对比度锚点下移避免压暗前景

## 架构

```
/dev/video14 (EASYCAMERA, MJPG 1280×720@30fps)
    │  ← V4L2 DMA
    ▼
  jpegdec ──────────→ CPU 解码 (libjpeg, 720p 快)
    │
    ▼
  glupload ────────→ GPU VRAM texture (1280×720 RGBA)
    │
    ▼
  glshader (enhance.frag, GLSL ES 1.00, 全 GPU fragment shader)
    │   Stage 0: Bicubic 超分 720p→1080p (Catmull-Rom 4×4)   [UPSCALE]
    │   Stage 1: 5×5 Gaussian 降噪                            [DENOISE]
    │   Stage 2: Adaptive unsharp 锐化                        [SHARPEN]
    │   Stage 3: Gamma 提亮 + Contrast + Saturation          [GAMMA/CONTRAST/SATURATION]
    ▼
  glcolorconvert ────→ NV12 (GPU 格式转换)
    │
    ▼
  gldownload ────────→ 仅 memcpy, 零计算
    │
    ▼
  v4l2sink → /dev/video99 (EnhancedCamera, v4l2loopback)
                    │
                    ▼
         OBS / 系统相机 / 任意 V4L2 应用
```

## CPU vs GPU 分工

| 阶段 | 执行位置 | 说明 |
|------|---------|------|
| V4L2 DMA capture | kernel | MJPG 压缩流 |
| jpegdec | **CPU** | 720p JPEG 解压 (~36% 单核) — VA-API→GL interop 在 Wayland+i915 不可用 |
| glupload | iGPU memory copy | system RAM → VRAM texture |
| glshader | **iGPU ALU** (gen9 HD 620) | 超分 + 降噪 + 锐化 + 色彩增强 |
| **超分辨率** | **iGPU FBO** | shader 渲染到 1920×1080 framebuffer, Catmull-Rom 4×4 bicubic |
| gldownload | memcpy only | VRAM → system buffer, 零计算 |
| v4l2sink | kernel DMABUF | 注入 loopback 设备 |

## 已验证结果（Lenovo Miix 720 / i5-7200U / HD 620）

```
输入:  /dev/video14  MJPG 1280×720 @ 30fps
输出:  /dev/video99  NV12 1920×1080 @ 30fps   ← GPU 超分 720p→1080p
CPU:   ~36% (仅 jpegdec 解压, 增强/超分全 GPU)
模式:  按需启停 — 有应用读取时激活增强链, 无读取者自动停止释放 video14
       延迟切换 0.7s (激活后等首帧积压再切, 无黑帧/卡顿)
Service: camera-enhancement.service (camera-router, active, enabled)
```

## 按需启停架构（camera-router 单进程整合）

**核心目标**：没有应用使用虚拟镜头时**不占用原始摄像头硬件**，用户可在原始前置镜头与增强版之间自由切换。

```
┌───────────────────────────────────────────────────────────────┐
│ camera-router (C, GStreamer C API, 单进程)                     │
│                                                               │
│  常驻部分 (不占 video14):                                      │
│    videotestsrc(black) → GL链 → input-selector → v4l2sink      │
│      → video99 永远有 writer → 格式永远有效 → 打开即成功        │
│                                                               │
│  动态部分 (reader 打开时):                                     │
│    v4l2src→jpegdec→GL→gldownload → selector request pad        │
│    inotify OPEN  → 添加增强链 → 延迟 0.7s 切 active-pad        │
│    inotify CLOSE → 切回静态帧 + 移除增强链 (video14 释放)        │
└───────────────────────────────────────────────────────────────┘
```

**延迟切换（0.7s，本摄像头量身定制）**：增强链从激活到首帧实测 ~0.5s
（v4l2src→jpegdec→GL 启动快），延迟 700ms 等数据在 queue 积压后再切
active-pad → 切换瞬间即有帧（无黑帧/卡顿）。OV5670 项目是 3s
（libcamera 启动慢），USB 摄像头更快，已按实测值定制
（`SWITCH_DELAY_MS=700`）。

### 关键技术决策

| 决策 | 原因 |
|------|------|
| **v4l2loopback `exclusive_caps=0`** | 设备同时声明 CAPTURE+OUTPUT，wireplumber 才能为 video99 创建 Video/Source Node（`exclusive_caps=1` 时有 writer 只显示 OUTPUT → 系统相机不枚举增强镜头）|
| **D-1 v4 内核补丁**（enum_fmt）| `exclusive_caps=0` 默认枚举 RGB 表（BGR4/RGB4/… 与 writer 的 NV12 不匹配 → PipeWire 协商 -22 EINVAL）。补丁让 ENUM_FMT 在 writer 分配缓冲后只返回实际格式 (NV12) |
| **HERMES-PATCH 内核补丁**（S_FMT）| writer 常驻时 CAPTURE token 被占 → reader 的 S_FMT 返回 EBUSY → 打不开。补丁让 reader 复用 writer 格式并授予 reader token |
| **单进程 C 整合** | 避免 watchdog 启停增强 pipeline 的竞态窗口（停空闲 writer → 启增强 之间无 writer，PipeWire 打开失败）。input-selector 毫秒级切换 pad，无窗口 |
| **动态增删增强链** | 无 reader 时整链从 pipeline 移除 → `/dev/video14` 真正释放（GStreamer 无法动态链接到已激活元素的固定 pad，整链增删是验证过的方案）|
| **WirePlumber 禁 v4l2 monitor 的 video14/video15** | 否则 pipewire 持续占用 video14，阻塞增强 pipeline 协商 (not-negotiated)。原始前置走 libcamera 通道，与增强不冲突 |

> ⚠️ **改输出分辨率后**：必须 `systemctl --user restart wireplumber` 刷新 PipeWire 的格式缓存，否则应用请求旧尺寸报 "could not play camera stream"。

## 安装

### 1. 依赖 (DKMS v4l2loopback + GStreamer GL + C 工具链)

```bash
sudo apt install dkms v4l2loopback-dkms v4l2loopback-utils \
                 gstreamer1.0-gl gstreamer1.0-plugins-base \
                 libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
                 gcc pkg-config
```

### 2. 应用内核补丁并编译 camera-router

```bash
# v4l2loopback 内核补丁 (D-1 v4 + HERMES-PATCH, 需 DKMS 重编译)
sudo python3 scripts/patch_v4l2loopback_enumfmt_fixed.py   # D-1 v4: ENUM_FMT 只返回 writer 格式
sudo dkms build -m v4l2loopback -v 0.15.4 -k $(uname -r) --force
sudo dkms install -m v4l2loopback -v 0.15.4 -k $(uname -r) --force

# 编译整合组件
# ⚠️ camera-router 为编译产物, 不入 git (front_camera/.gitignore, 从未被跟踪);
#    源码 pipeline/camera-router.c 为准
cd pipeline/
gcc -o camera-router camera-router.c $(pkg-config --cflags --libs gstreamer-1.0 gstreamer-video-1.0) -lpthread
```

### 3. 安装服务

```bash
cd scripts/
chmod +x install_service.sh
./install_service.sh           # 写入 modules-load.d + modprobe.d + systemd user service + 自动验证
systemctl --user start camera-enhancement
```

（可加 `--dry-run` 预览。安装脚本会**自动验证**：模块加载、/dev/video99 存在、
开机持久化配置有效、服务已启用。）

> ⚠️ **启动时机（黑屏修复）**：服务绑定 `graphical-session.target`
> （`After` + `PartOf` + `WantedBy`），**进桌面后**才启动 camera-router —
> 它需要 Wayland 显示服务器初始化 GL 上下文。**切勿改回 `default.target`**：
> 登录早期无显示 → `pipeline PLAYING failed` → `Restart=on-failure` 无限重启
> → 系统黑屏无法进桌面（实测事故）。
>
> **wireplumber 枚举自动修复**：`ExecStartPost` 运行
> `camera-enhancement-wireplumber-refresh.sh` — 等 writer 就绪后重启
> wireplumber，修复登录时枚举过"无 writer"的 video99 的病态节点缓存
> （否则应用协商失败、系统相机打不开增强镜头）。

> ⚠️ **重启后看不到 EnhancedCamera？** 依次检查：
> 1. `lsmod | grep v4l2loopback` — 模块未加载则 `/etc/modules-load.d/usb-camera-enhancement.conf` 可能为空（安装脚本会检测并重写）
> 2. `grep exclusive_caps /etc/modprobe.d/usb-camera-enhancement.conf` — 应为 `exclusive_caps=0`（=1 时系统相机不枚举增强镜头）
> 3. `systemctl --user is-enabled camera-enhancement` — 应显示 enabled
> 4. `systemctl --user restart wireplumber` — 刷新 PipeWire 设备枚举（增强镜头出现在源列表）

### 4. 使用

在 OBS / 系统相机 / 任意应用中，选择 **`EnhancedCamera`** (`/dev/video99`)。

## 调节画质参数

编辑 `shaders/enhance.frag` 中参数，然后 `systemctl --user restart camera-enhancement`：

| 参数 | 范围 | 默认 | 效果 |
|------|------|------|------|
| `UPSCALE`    | 0/1 | 1.0  | 1 = bicubic 720p→1080p 放大; 0 = 720p 原生输出 |
| `DENOISE`    | 0.0~2.0 | 1.5  | 5×5 Gaussian 降噪强度 |
| `SHARPEN`    | 0.0~3.0 | 2.0  | Adaptive unsharp 锐化 |
| `CONTRAST`   | 1.0~1.5 | 1.12 | 对比度倍增（锚点 0.45，避免压暗暗部）|
| `SATURATION` | 1.0~2.0 | 1.35 | 色彩饱和度 |
| `GAMMA`      | 0.7~1.3 | 0.82 | <1.0 提亮暗部（低光友好）|

**低光照推荐**：`DENOISE=1.8, SHARPEN=1.5, GAMMA=0.78, SATURATION=1.3`

## 手动运行 / 调试

```bash
./pipeline/camera-router        # 前台运行 (需图形会话, shader 自动生成)
journalctl --user -u camera-enhancement -f   # 日志
```

## 技术要点

### 为什么不用 VA-API VPP？
Ubuntu 26.04 的 GStreamer 1.26.8 **移除了 `vaapipostproc` VPP 滤镜**，只剩硬解/编码。
因此所有画质增强走自定义 GL shader —— 这反而更灵活（自定义降噪/锐化/色彩算法）。

### 为什么 shader 是 GLSL ES 1.00？
Wayland/EGL 下 GStreamer 创建 GLES 2.0 context → GLSL ES 1.00 语法：
`varying`/`texture2D`/`gl_FragColor` + 显式 `precision`；ES 1.00 禁止数组构造器
（bicubic 4×4 权重需手动展开）。

### 为什么 GStreamer CLI 需要 make_shader.py？
`gst-launch-1.0` 命令行解析器对属性值敏感：多行值会拆 token、`#` 会被当注释。
`scripts/make_shader.py` 生成单行、无 `#` 指令、无 `//` 注释的 GLSL 源码注入。
（camera-router.c 启动时自动调用 make_shader.py 生成 shader。）

### 为什么用 C 而不是 Python (gi)？
Python `gi` 绑定 + GStreamer GL 元素（glupload/glshader/gldownload）在动态增删/selector 组合下
实测会 `free(): double free` 崩溃（静态与动态管线都触发）。同一管线用 GStreamer C API 稳定运行。
另外：GStreamer 无法动态链接到已运行 pipeline 中已激活元素的固定 pad —— 因此增强链采用
**整链动态增删**（`gst_bin_add/remove` + request pad），这也是 video14 能真正释放的原因。

### v4l2loopback 枚举格式的坑（D-1 补丁演进记录）
`exclusive_caps=0` 时 `vidioc_enum_fmt_vid` 枚举完整 RGB 表（BGR4/RGB4/… 72 个假格式），
spa-v4l2/PipeWire 协商选 RGB 但 writer 实际写 NV12 → link 失败 `-22 EINVAL`（系统相机报错打不开）。

补丁演进（`scripts/patch_v4l2loopback_enumfmt_fixed.py`）：
- v2：`pix_format != 0` 判断 — 错误（pix_format 默认 BGR4 非零）→ 枚举锁死 BGR4，v4l2sink 协商 NV12 失败
- v3：`has_other_owners` — 破坏 reader STREAMON（同一 token 逻辑也驱动 S_FMT/REQBUFS → 读 EIO）
- **v4（最终）**：`dev->image != NULL`（writer 已分配缓冲）→ 只枚举当前格式，与 opener token 正交，reader 不受影响

## 故障排查

| 问题 | 检查 |
|------|------|
| `/dev/video99` 不存在 | `lsmod \| grep v4l2loopback`; `sudo modprobe v4l2loopback exclusive_caps=0 card_label=EnhancedCamera video_nr=99` |
| 应用看不到 EnhancedCamera | `v4l2-ctl --list-devices \| grep Enhanced`; `systemctl --user restart wireplumber` |
| 系统相机能看到但打不开 (-22) | 确认 D-1 v4 补丁已编译进模块（`v4l2-ctl -d /dev/video99 --list-formats` 应只显示 NV12）|
| "could not play camera stream" | 改过分辨率后需 `systemctl --user restart wireplumber` 刷新缓存 |
| GL context 错误 | 必须在图形会话运行; `systemctl --user start` |
| 想看 shader 效果 | 对比 `ffmpeg -i /dev/video14` 与 `/dev/video99` 抓帧 |

## License

[GPL-3.0](LICENSE) — luoshirong-gmail
