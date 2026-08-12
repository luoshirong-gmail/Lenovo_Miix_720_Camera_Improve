# 升级手册 — 内核升级 / v4l2loopback 补丁重打 / 模块重装

> 适用: Lenovo_Miix_720_Camera_Improve 项目（合并版）
> 前提: 主板硬件驱动由另一项目（ov5670_driver）维护；本手册只覆盖**功能提升层** (v4l2loopback)

## 何时需要本流程

- **内核升级** (uname -r 变化) → dkms 自动重编译无补丁模块 → 补丁丢失
- **v4l2loopback 重装 / 误还原官方版** → 补丁丢失
- **行为异常排查** (相机打不开 / 枚举格式错 / pipewire SEGV / "can't allocate enough buffers")

## 一、检查补丁状态

```bash
# 只读检查 (不修改任何文件)
python3 common/v4l2loopback-patches/apply_all.py --check

# 期望输出: 6 个补丁全部 ✅ 已应用
#   D-1 v4 (enum_fmt)          → ✅ 已应用
#   HERMES-PATCH (s_fmt)       → ✅ 已应用
#   MIN-3 (reqbufs)            → ✅ 已应用
#   IMAGE-ON-DEMAND (reqbufs)  → ✅ 已应用
#   HERMES-PATCH-3 (fileio)    → ✅ 已应用
#   HERMES-PATCH-4/5 (streamon/fileio) → ✅ 已应用
```

输出 `❌ 缺失` = 需要重打；输出 `❌ 目标代码未找到` = 版本不符
（检查 v4l2loopback 是否 0.15.4）。

> 权威源码: `back_camera/patched-sources/v4l2loopback/v4l2loopback.c`
> （同步 /usr/src/v4l2loopback-0.15.4/v4l2loopback.c，含全部 5 个 HERMES 补丁）。

## 二、应用补丁 + 编译 + 签名 + 安装

```bash
cd ~/Projects/Lenovo_Miix_720_Camera_Improve

# 1. 应用缺失补丁 (需 root — 写 /usr/src)
sudo python3 common/v4l2loopback-patches/apply_all.py

# 2. 编译 (dkms 源码树)
cd /usr/src/v4l2loopback-0.15.4
sudo make -C /lib/modules/$(uname -r)/build M=$PWD

# 3. 签名 (MOK 密钥来自系统 /usr/local/share/mok, 属硬件项目资产, 只引用不复制)
sudo kmodsign sha512 /usr/local/share/mok/MOK.key /usr/local/share/mok/MOK.der v4l2loopback.ko

# 4. 安装到 updates/ (优先级高于 kernel/)
#    ⚠️ .ko.zst 是 dkms 当前版本文件, 勿删! 只删旧版本残留的 .ko.zst
sudo rm -f /lib/modules/$(uname -r)/updates/dkms/v4l2loopback.ko.zst
sudo cp v4l2loopback.ko /lib/modules/$(uname -r)/updates/dkms/
sudo depmod -a

# 5. 验证签名
modinfo v4l2loopback | grep -E '^(version|srcversion|filename)'
# 2026-08-12 基线: srcversion 7217A34E... (PATCH-3/4/5)
```

> 或直接 DKMS: `sudo dkms remove v4l2loopback/0.15.4 --all && sudo dkms add
> v4l2loopback/0.15.4 && sudo dkms build v4l2loopback/0.15.4 --force && sudo
> dkms install v4l2loopback/0.15.4 --force`（源码树已含补丁时）。

## 三、模块重载 + 设备重建 + 服务恢复

```bash
# ⚠️ 重载前必须先停两个服务 (它们持有 video99/video16)
systemctl --user stop camera-enhancement.service ov5670-virtual-camera.service
pkill -9 -f 'camera-router|ov5670-router' 2>/dev/null; sleep 1

# 重载模块 (读 modprobe.d → exclusive_caps=0)
sudo modprobe -r v4l2loopback && sudo modprobe v4l2loopback

# ⚠️ 重载后必须核对 exclusive_caps=0 (历史事故: 无参数加载变 1 → 相机全失效)
cat /sys/module/v4l2loopback/parameters/exclusive_caps   # 期望 0,0,0,...

# 重建动态设备 (video16 是 v4l2loopback-ctl add 动态创建, 重启/重载后消失)
sudo v4l2loopback-ctl add -n "OV5670 Back Camera" -w 3840 -h 2160 -b 16 -x 0 16

# 重启两个服务
systemctl --user start camera-enhancement.service ov5670-virtual-camera.service

# 重启 wireplumber (枚举缓存与设备状态可能不一致)
systemctl --user restart wireplumber.service
```

## 四、验证

```bash
# 设备在位
v4l2-ctl --list-devices | grep -E 'video99|video16'

# video16 出流 (后置虚拟, 写端解耦)
v4l2-ctl -d /dev/video16 --get-fmt-video

# 枚举格式只 NV12 (D-1 生效)
v4l2-ctl -d /dev/video16 --list-formats

# 系统相机打开 (Snapshot) → 流畅 + AF 对焦
# router 日志: "写端就绪: /dev/video16 O_WRONLY NV12 ... REQBUFS(3)"
#             "OV5670 已激活 (cam PLAYING, 真实流)"
```

## 五、补丁链原理速查 (为什么必须)

| 补丁 | 位置 | 作用 | 缺失症状 |
|---|---|---|---|
| D-1 v4 | vidioc_enum_fmt_vid | 有 writer 时只列当前格式 (NV12) | 枚举 RGB 表 → 协商 EINVAL (-22) |
| HERMES-PATCH | vidioc_s_fmt_vid | writer 活跃时 reader S_FMT 复用格式 | reader EBUSY → 相机打不开 |
| MIN-3 | vidioc_reqbufs | writer REQBUFS ≥3 (PipeWire 下限) | "can't allocate enough buffers 2 < 3" |
| IMAGE-ON-DEMAND | vidioc_reqbufs | 无 image 时也分配 | 重启后必现 -22 (D-1 失效) |
| HERMES-PATCH-3 | start_fileio | write() REQBUFS 用 used_buffer_count | pipewire SEGV (缓冲被撑 16) |
| HERMES-PATCH-4 | vidioc_streamon | 读端 STREAMON 不因写端流激活 EIO | 黑屏 (pipewire 无法流) |
| HERMES-PATCH-5 | start_fileio | 写端 io_method=MMAP 转 FILE 允许 | write() EBUSY → 0 帧黑屏 |

> PATCH-3/4/5 是 2026-08-12 写端解耦方案（appsink→write()）的配套。
> 若未来回退到 v4l2sink 写端，可仅保留前 4 个补丁。

## 六、历史事故清单（勿重蹈）

1. **exclusive_caps 变 1**: 模块无参数加载 → 两相机全失效。重载后必查
   `/sys/module/v4l2loopback/parameters/exclusive_caps`
2. **.ko.zst 乱删**: dkms 当前版本文件就是 .ko.zst, 删了 → dracut 报
   "could not get modinfo"。只删旧版本残留
3. **reader > writer buffer → SEGV**: v4l2loopback 共享缓冲, reader 拿
   比 writer 多 → 越界崩溃 (pipewire core-dump)。MIN-3 只提升 writer
4. **keep_format=1 锁格式**: 重启后设备默认 BGR4 + keep_format → ENUM_FMT
   只报 BGR4 → router NV12 协商失败崩溃。已移除 (PATCH-4 正本清源)
5. **MIN-4 破坏写端轮转**: 改 MIN-3→MIN-4 (内核给 4, GStreamer pool 仍 3)
   → DQBUF index 错位 "not queued" → 崩溃。改 MIN 缓冲是死路
6. **双流 viewfinder 负优化**: libcamerasrc 双流 (main+viewfinder) 帧率大跌
   (ImgU 双流调度开销)。已回退单流
7. **编译假成功**: `gcc ... | head` 管道吞退出码 → 旧二进制覆盖新源码。
   编译必须看 gcc 直接退出码
8. **initramfs 打包旧模块**: videodev 系模块在 initramfs 里, 换 /lib/modules
   不够。必须 `update-initramfs -u -k <ver>` + `lsinitramfs` 验证
9. **多进程污染**: 调试时残留多个 writer → 单 writer 冲突 → 误判补丁无效。
   清理: stop 服务 + pkill -9 + pgrep 确认空
