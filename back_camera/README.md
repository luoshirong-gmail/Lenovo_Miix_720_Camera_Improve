# OV5670 后置摄像头虚拟设备转发系统 (ov5670-universalization)

按需将 Lenovo MIIX 720 的 OV5670 后置摄像头（IPU3 管线）转发到 v4l2loopback
虚拟设备 **/dev/video16**（2026-08-07 起，原 /dev/video98 已废弃），为所有应用
提供 **2560×1920 NV12 29fps 实时画面**，支持自动对焦与左右翻转。

**最终状态 (2026-08-07)：C' 方案完成，系统相机正常，idle CPU ≈ 0%**

## 架构（C' 极简方案）

```
libcamerasrc(PAUSED 常驻) → videoconvert → videoflip(4) → capsfilter → queue → v4l2sink(/dev/video16)
        ↑ activate: PAUSED→PLAYING（只开流）   ↑ deactivate: PLAYING→PAUSED（停流保持 acquire）
```

- **无 idle 链、无 input-selector**：没有 user 时不需要推黑帧（推给谁看？）
- **PAUSED 常驻**：open/acquire/配置在 pipeline 启动时完成（与 gst-launch 语义
  对齐）→ activate 只 PLAYING 即出帧，**不重新 open**（这是 C' 成立的核心：
  之前 READY/NULL 方案在 activate 时重新 open → loop 不推帧）
- **wireplumber CAM6 屏蔽**（`51-libcamera-disable-cam6.conf`）：router 独占
  CAM6，PAUSED 持有 acquire 无副作用；物理后摄不给应用，虚拟 video16 替代
- **按需激活**：inotify IN_OPEN/IN_CLOSE → 600ms 复查 has_real_reader()
  （排除 wireplumber 枚举瞬时打开）→ activate/deactivate
- **灾难恢复**：GStreamer bus 监听 ERROR/EOS → 退出(exit 1) → systemd
  Restart=on-failure → ExecStartPre ensure-device 重建设备 → 自动恢复

## 关键文件

| 文件 | 说明 |
|---|---|
| `scripts/ov5670-router.c` | 主程序（C' 极简，GStreamer 管线 + inotify 事件驱动 + bus 监听 + AF 触发/心跳/跨帧重发/busy 等待）|
| `scripts/ov5670-router` | 编译产物（gitignore）|
| `scripts/ov5670-ensure-device.sh` | systemd ExecStartPre：确保 /dev/video16 存在（v4l2loopback-ctl add -x 0 16）|
| `scripts/ov5670-virtual-camera.service` | systemd 用户服务（graphical-session.target）|
| `scripts/install_af.sh` | v4l2loopback AF 控件补丁安装脚本（P1-P5）|
| `scripts/patch_v4l2loopback_af.py` | v4l2loopback 补丁（AF 控件 D-1+HERMES+MIN-3）|
| `config/51-libcamera-disable-cam6.conf` | CAM6 屏蔽规则 |
| `ipa-patches/` | IPU3 IPA 自动对焦补丁（af.cpp/af.h，a/b 格式）|
| `gst-patches/` | GStreamer libcamerasrc AF 属性说明（官方 0.7 已支持）|
| `tuning/` | 画质调校资产（ov5670.yaml + Intel 官方 AIQ 调校）|

## 自动对焦与画质（2026-08-08）

- **自动对焦**：三模式（manual/auto/continuous）完整修复，详见
  `docs/ov5670-autofocus.md`（触发可靠性跨帧重发、失焦判定归一化方差/
  自适应基准/连续确认、auto 扫描精度细扫固定轨迹/历史最佳、40s 锁定窗口）。
- **画质调校**：`tuning/ov5670.yaml` 设置 AGC 目标亮度 0.35（默认 0.16 画面暗），
  实测亮度 43.5→132.6 提亮 3 倍；Intel 官方 ov5670 AIQ 调校已归档
  （`tuning/01ov5670.aiqb`，Apache 2.0），供后续完整 3A 调校。

## 构建与运行

```bash
# ① 模块加载 — 2026-08-09 根治 (initramfs 预加载)
#    ⚠️ 教训: 项目配置必须自包含, 不依赖 USB 增强项目的 conf
#    ⚠️ 教训: 开机加载 v4l2loopback 必须用 modprobe 命令 (systemd-modules-load
#      的 kmod 库解析 modprobe.d options 不完整 → add 设备 AF 控件 0/3);
#      且 modules-load.d 曾被打包进 initramfs → initrd 阶段预加载旧模块 →
#      root 阶段全部改动无效。根治 = 注释 modules-load.d + 专用服务加载 +
#      update-initramfs 重新打包。
sudo cp config/ov5670-modprobe.conf /etc/modprobe.d/ov5670-virtual-camera.conf
sudo cp config/ov5670-modules-load.conf /etc/modules-load.d/ov5670-virtual-camera.conf  # v4l2loopback 已注释
sudo cp systemd/v4l2loopback-load.service /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable v4l2loopback-load.service
sudo update-initramfs -u   # 关键: 让 initramfs 内的 modules-load.d 同步为注释版

# ② 开机自愈: exclusive_caps 异常 (数组 Y) 自动重载模块 (After v4l2loopback-load)
sudo cp config/ov5670-ec-fix.sh /usr/local/sbin/ && sudo chmod +x /usr/local/sbin/ov5670-ec-fix.sh
sudo cp config/ov5670-ec-fix.service /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable ov5670-ec-fix.service

# ③ 编译
cd scripts
gcc -O2 -Wall -o ov5670-router ov5670-router.c \
    $(pkg-config --cflags --libs gstreamer-1.0) -lpthread
systemctl --user daemon-reload
systemctl --user enable --now ov5670-virtual-camera.service

# ④ 对焦控件自愈 (双保险, 普通用户权限, 不碰前摄) — 脚本已在 scripts/
cp systemd/ov5670-af-selfheal.service ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable ov5670-af-selfheal.service
```

## 关键机制（踩坑记录，2026-08-07）

### 1. C' 核心：PAUSED 常驻 vs READY/NULL 重新 open ★最重要
- **READY/NULL 方案**：deactivate 释放后 activate 时 libcamerasrc 重新 open
  → **configuring 成功但 GStreamer loop 不推帧**（libcamera 层出帧、
  requestCompleted 持续，但 buffer 不进 pipeline）→ 切换超时。
- **PAUSED 常驻**：open/acquire 在 pipeline 启动时完成（与 gst-launch L3
  291 帧的语义对齐）→ activate 只 PAUSED→PLAYING → **loop 正常推帧**。
- CAM6 屏蔽后 PAUSED 持有 acquire 无副作用（物理后摄不给应用）。

### 2. camera-name 双转义陷阱
gst_parse_launch 对双引号属性值做**双层转义**（\\→\→丢）→ CAM6 的 `\` 被吃光
→ "Could not find a camera named '_SB_...'"。**parse 后 g_object_set 直接设置**。

### 3. wireplumber CAM6 屏蔽（51 规则）
`api.libcamera.path = "\_SB_.PCI0.I2C2.CAM6"` 匹配 → 应用看不到物理后摄。
只匹配 CAM6，**前摄（video14 v4l2 + UVC libcamera）不受影响**。

### 4. 腾讯会议限制（实测结论）
- **只枚举连续段 video0-15**：虚拟设备在 video98 看不到 → **迁移到 video16**
  （紧邻空槽，枚举到第一个不存在就停的逻辑下可见）。
- **UVC-only 倾向**：driver 名改 "uvcvideo" 后**能看到选项**。
- **选择后黑屏**：2560×1920 超出腾讯会议 720p 上限（reader 不重置 writer
  buffer 的补丁已具备，非 buffer 问题）→ **腾讯会议走物理前摄**，虚拟后摄
  用于其他应用（系统相机 Snapshot 等正常）。
- 腾讯会议 reader 不耐受 cam 激活空窗（~1s 内 STREAMON 后 DQBUF 阻塞退出），
  曾试"IN_OPEN 立即激活"缩空窗 → 仍黑屏（分辨率是主因）→ **已回退**为
  600ms 延迟复查（立即激活会让 wireplumber 枚举误激活 cam，违背按需）。

### 5. v4l2loopback 补丁（D-1+HERMES+MIN-3+IMAGE-ON-DEMAND，srcversion 965BFF8F）
- D-1：ENUM_FMT 只返回 writer 格式（NV12）
- MIN-3：writer REQBUFS 提升到 3（PipeWire 要求）
- IMAGE-ON-DEMAND：reader 打开时按需分配 image
- **reader 不重置 writer buffer**：已实现（v4l2loopback.c 补丁）

### 6. v4l2loopback 源码关键机制（DQBUF 唤醒）
- `can_read`：`write_position > read_position` → DQBUF 唤醒条件
- `buffer_written`：`used_buffer_count != 0` 才 ++write_position
- `vidioc_streamon(CAPTURE)`：`has_output_token && !keep_format` → -EIO
- reader REQBUFS count 变化会重建 buffer 池（已补丁避免影响 writer）

### 7. 灾难恢复链
bus ERROR（CAM6 流错误/v4l2sink 写失败/video16 被删）→ exit(1) → systemd
Restart=on-failure(3s) → ensure-device 重建 → libcamerasrc 重新初始化 → 恢复。
极端 kill -9 同样自愈（实测）。

### 8. 其他保留经验
- videoflip `method=4` = horizontal-flip（method=2 是 rotate-180）
- libcamera 0.7 IPU3 AF 自动（不要设 af-mode=2）
- /tmp 配额陷阱（v4l2-ctl 抓帧占满 → 先 `df -h /tmp`）

## 摄像头上下文

- OV5670 camera ID: `\_SB_.PCI0.I2C2.CAM6`
- VCM: dw9719 @ `/sys/bus/i2c/devices/i2c-INT3479:00-VCM`
- `/dev/video16`: 动态创建（ensure-device.sh，`-x 0`）
- `/dev/video99`: USB 增强项目占用（camera-enhancement.service），互不干扰
- v4l2loopback 模块参数（modprobe.d）：
  `exclusive_caps=0 max_width=3840 max_height=2160 max_buffers=16 card_label=EnhancedCamera video_nr=99`
- 补丁源码：`/usr/src/v4l2loopback-0.15.4/v4l2loopback.c`

## 验证结果（2026-08-07 最终）

- ✅ **3/3 连续开关全真实帧**（80 帧 4/4，PAUSED→PLAYING 正常出帧）
- ✅ **wireplumber 枚举正常**（离散 29/1，无病态 Continuous）
- ✅ **系统相机（Snapshot）正常**（方向/对焦/连续开关）
- ✅ **前摄可见**（video14 UVC + 屏蔽规则不影响）
- ✅ **CAM6 屏蔽生效**（应用只见 video16 虚拟后摄）
- ✅ **灾难恢复**（kill -9 实测 systemd 自动重启）
- ⚠️ **腾讯会议**：可见选项（video16 + driver uvcvideo）但黑屏（分辨率 720p 上限，放弃）
