#!/bin/bash
# camera-enhancement-autostart.sh — 登录后启动 USB 画质增强 (2026-08-06)
#
# 背景: camera-enhancement.service 原为 linger 开机启动 (登录前), 其 GL
#   初始化与 GDM 的 GNOME Shell 争抢 DRM master → GNOME Shell open GPU EBUSY
#   → "No GPUs found" → 黑屏无法进桌面 (7.0.0-29 实测复现)。
#   改为登录后 (桌面就绪) 启动: GL 作为 wayland 客户端连接现有 compositor,
#   不再抢 master → 无冲突 (实测验证: 登录后启动 GNOME Shell 存活)。
#
# 用法: GNOME autostart (~/.config/autostart/camera-enhancement.desktop) 调用

export XDG_RUNTIME_DIR=/run/user/$(id -u)
export WAYLAND_DISPLAY=wayland-0
export DISPLAY=:0

# 1. 启动 camera-router (保留 service 的 Restart=on-failure 逻辑)
systemctl --user start camera-enhancement.service

# 2. 等 writer 就绪 (video99 state=capture, 最多 15s)
for i in $(seq 1 30); do
    [ "$(cat /sys/class/video4linux/video99/state 2>/dev/null)" = "capture" ] && break
    sleep 0.5
done

# 3. 刷新 wireplumber: 登录时 wireplumber 枚举过"无 writer"的 video99,
#    节点缓存病态 (EnumFormat 异常) → 重启重新枚举 (与 ov5670 同款机制)
systemctl --user restart wireplumber

exit 0
