#!/bin/bash
# ov5670-ec-fix.sh — 开机自愈: 修复 v4l2loopback exclusive_caps 数组异常
# 背景 (2026-08-07): 开机时 systemd-modules-load (kmod 库) 加载 v4l2loopback
# 未正确应用 modprobe.d 的 exclusive_caps=0 → 数组出现 Y → video16 枚举
# Range 帧率 → 应用打不开。手动 modprobe (读 modprobe.d) 则正常。
# 修复: 检测数组含 Y → 重载模块 (读 modprobe.d 恢复全 N)。
# 开机早期运行 (After=systemd-modules-load, Before=user 会话) — 无应用使用
# 设备, 重载安全; 重载后 video99 (modprobe.d video_nr=99) 重建,
# video16 由 ov5670 ensure-device 在 user 服务启动时动态创建。

EC_FILE=/sys/module/v4l2loopback/parameters/exclusive_caps

[ -r "$EC_FILE" ] || exit 0

if grep -q 'Y' "$EC_FILE"; then
    echo "ov5670-ec-fix: exclusive_caps 含 Y ($(cat "$EC_FILE")), 重载模块..."
    modprobe -r v4l2loopback
    modprobe v4l2loopback
    echo "ov5670-ec-fix: 重载完成, exclusive_caps = $(cat "$EC_FILE")"
else
    echo "ov5670-ec-fix: exclusive_caps 正常, 无需处理"
fi
exit 0
