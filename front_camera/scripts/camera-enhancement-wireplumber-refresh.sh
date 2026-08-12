#!/bin/bash
# camera-enhancement-wireplumber-refresh.sh — writer 就绪后修复 wireplumber 枚举
# (2026-08-06, 与 ov5670-wireplumber-refresh.sh 同款机制)
#
# 背景: 登录时 wireplumber 先枚举 video99 (此刻无 writer, 仅 Device 无 Node),
#   节点缓存病态 (EnumFormat 异常 → 应用协商失败 → 系统相机打不开增强镜头)。
#   本脚本由 camera-enhancement.service 的 ExecStartPost 调用:
#   - 等 video99 有 writer (state=capture, 最多 15s)
#   - 重启 wireplumber 重新枚举 → 枚举到带 writer 的 video99 → Node 格式正确
#
# 合并说明: 这是原 autostart 方案 (camera-enhancement-autostart.sh) 的核心
#   价值 — 与 systemd graphical-session.target 启动时机方案合并后,
#   启动时机由 service 的 After=graphical-session.target 保证, 本脚本只负责
#   枚举修复 (不再用 autostart desktop, 避免双启动源)。

export XDG_RUNTIME_DIR=/run/user/$(id -u)

# 1. 等 writer 就绪 (video99 state=capture, 最多 15s)
for i in $(seq 1 30); do
    [ "$(cat /sys/class/video4linux/video99/state 2>/dev/null)" = "capture" ] && break
    sleep 0.5
done

# 2. 刷新 wireplumber: 重新枚举 (writer 在线时枚举 → 固定格式 → 应用协商成功)
systemctl --user restart wireplumber

exit 0
