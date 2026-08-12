# 合并前系统基线 (P0) — 2026-08-08 01:18 CST

## 用途
合并项目 `Lenovo_Miix_720_Camera_Improve` 建立时的系统状态快照，
供 P6 验证阶段逐项对照，确保合并过程不改变系统运行状态。

## 系统环境
- 主机: Lenovo MIIX 720-12IKB (80VV), Ubuntu Resolute (26.04), kernel 7.0.0-29-generic
- 摄像头硬件: 前置 EasyCamera (04f2:b5b8, UVC /dev/video14-15) / 后置 OV5670 (CAM6, IPU3 管线)
- 前提: 主板硬件驱动（TPS68470 电源、OV5670 驱动、dw9719 对焦、ipu3-cio2 等）由**另一独立项目**维护，
  本摄像头优化项目只做功能提升层，不涉及内核模块源码修改。

## 服务状态
| 服务 | 状态 | 设备 | 功能 |
|---|---|---|---|
| camera-enhancement.service | active | video14 → video99 | 前置 GL 增强 |
| ov5670-virtual-camera.service | active | CAM6 → video16 | 后置虚拟摄像头 (C' 架构) |

## v4l2loopback 模块
- 版本: 0.15.4, srcversion: 0F922DEAF5EAF3535F4E46F
- 路径: /lib/modules/7.0.0-29-generic/updates/dkms/v4l2loopback.ko
- 源码补丁标记: D-1=2, HERMES=3, MIN-3=1, IMAGE-ON-DEMAND=1, CID_FOCUS=0 (对焦已回滚)

## v4l2 设备 (合并前)
- ipu3-imgu: /dev/video4-13
- Intel IPU3 CIO2: /dev/video0-3
- OV5670 Back Camera (v4l2loopback-016): /dev/video16
- EnhancedCamera (v4l2loopback-099): /dev/video99
- EasyCamera: /dev/video14-15

## 系统配置 (合并前)
- /etc/modprobe.d/usb-camera-enhancement.conf — options v4l2loopback exclusive_caps=0 max_width=3840 max_height=2160 max_buffers=16 card_label=EnhancedCamera video_nr=99
- /etc/modprobe.d/ov5670-virtual-camera.conf — options v4l2loopback exclusive_caps=0 max_width=3840 max_height=2160 max_buffers=16 (无 video_nr)
- /etc/modules-load.d/ov5670-virtual-camera.conf — v4l2loopback (启用)
- /etc/modules-load.d/usb-camera-enhancement.conf.disabled — v4l2loopback (已禁用)
- ~/.config/wireplumber/wireplumber.conf.d/51-libcamera-disable-cam6.conf — CAM6 屏蔽 (router 专用)
- ~/.config/wireplumber/wireplumber.conf.d/50-v4l2-disable-easycamera.conf.disabled — EasyCamera 屏蔽 (已禁用)
- systemd user services: camera-enhancement.service + ov5670-virtual-camera.service (均 active+enabled)
- systemd system: ov5670-ec-fix.service (EC Y=kmod 自愈)

## 源项目 git 状态
| 项目 | git | 历史 |
|---|---|---|
| USB_Camera_Enhancement | ✅ 工作区干净 | 有 (最新 183fbff) |
| Lenovo_Miix_720_Camera/ov5670_universalization | ❌ 非 git 仓库 | 无 (复制 + docs 溯源) |

## 合并边界 (用户确认)
- ✅ 纳入: 前置增强 (front_camera) + 后置虚拟摄像头 (back_camera) + 共享 v4l2loopback 补丁链/系统配置
- ❌ 排除: IR_Camera、ov5670_autofocus (对焦已回滚)、Final_Patches 内核补丁包 (归硬件驱动项目)、MOK 密钥资产
- 📌 旧项目目录: 不删除任何内容，整体保留为历史备份存档
- 🚫 GitHub: 不配置 remote、不推送，本地 git 仅版本管理
