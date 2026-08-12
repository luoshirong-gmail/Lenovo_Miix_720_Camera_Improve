#!/bin/bash
# hermes-verify-module-params.sh — ad-hoc 验证 (2026-08-09 04:3x)
# 本回合根治: modprobe.d video_nr=99,16 + card_label 数组 —
# video16 由模块参数创建 (开机即带对焦控件, 不依赖 add 时机)
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }

echo "=== 1. 模块参数 (核心) ==="
echo "video_nr: $(cat /sys/module/v4l2loopback/parameters/video_nr 2>/dev/null)"
cat /sys/module/v4l2loopback/parameters/video_nr 2>/dev/null | grep -q '16' && ok "video_nr 含 16 (video16 模块参数创建)" || bad "video_nr 缺 16"
echo "exclusive_caps: $(cat /sys/module/v4l2loopback/parameters/exclusive_caps 2>/dev/null)"
cat /sys/module/v4l2loopback/parameters/exclusive_caps 2>/dev/null | grep -q 'N,N,N,N,N,N,N,N' && ok "exclusive_caps 全 N" || bad "exclusive_caps 异常"

echo "=== 2. conf 配置 ==="
grep -q 'video_nr=99,16' /etc/modprobe.d/usb-camera-enhancement.conf && ok "conf 含 video_nr=99,16" || bad "conf 缺 video_nr"
grep -q 'card_label=EnhancedCamera' /etc/modprobe.d/usb-camera-enhancement.conf && ok "conf 含 card_label 数组" || bad "conf 缺 card_label"

echo "=== 3. video16 (模块参数创建) ==="
v4l2-ctl -d /dev/video16 --info 2>/dev/null | grep -q 'OV5670' && ok "video16 card 含 OV5670" || bad "video16 card 异常"
N=$(v4l2-ctl -d /dev/video16 --list-ctrls 2>/dev/null | grep -cE 'af_trigger|focus_auto|focus_absolute')
[ "$N" = "3" ] && ok "video16 对焦控件 3/3" || bad "控件 $N/3"

echo "=== 4. 服务 + 其他设备 ==="
systemctl --user is-active ov5670-virtual-camera.service | grep -q active && ok "后摄 active" || bad "后摄异常"
systemctl --user is-active camera-enhancement.service | grep -q active && ok "前摄 active" || bad "前摄异常"
v4l2-ctl -d /dev/video99 --info 2>/dev/null | grep -q 'EnhancedCamera' && ok "video99 EnhancedCamera" || bad "video99 异常"

echo ""
echo "════════ 结果 ════════"
echo "PASS=$PASS FAIL=$FAIL (ad-hoc 验证, 非套件; 脚本保留 /tmp/hermes-verify-module-params.sh 供复查)"
exit $FAIL
