#!/bin/bash
# hermes-verify-af-unconditional.sh — ad-hoc 验证 (2026-08-09 04:5x)
# 本回合根治: v4l2loopback.c 无条件注册 AF 控件 (第四次复发)
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }

echo "=== 1. 新模块 (无条件注册) ==="
ls -la /lib/modules/$(uname -r)/updates/dkms/v4l2loopback.ko.zst | awk '{print "  .ko.zst: "$5" B, "$6" "$7" "$8}'
grep -q '无条件注册' /usr/src/v4l2loopback-0.15.4/v4l2loopback.c && ok "源码无条件注册 (3090)" || bad "源码未改"
grep -q 'ov5670-af-20260809' /usr/src/v4l2loopback-0.15.4/v4l2loopback.c && ok "补丁注释在位" || bad "注释缺失"

echo "=== 2. video16 控件 (核心) ==="
N=$(v4l2-ctl -d /dev/video16 --list-ctrls 2>/dev/null | grep -cE 'af_trigger|focus_auto|focus_absolute')
[ "$N" = "3" ] && ok "video16 对焦控件 3/3" || bad "控件 $N/3"

echo "=== 3. 手动 add 无条件注册 (决定性) ==="
v4l2loopback-ctl add -n "OV5670 Test" -w 3840 -h 2160 -b 16 -x 0 17 2>/dev/null
sleep 1
N17=$(v4l2-ctl -d /dev/video17 --list-ctrls 2>/dev/null | grep -cE 'af_trigger|focus_auto|focus_absolute')
[ "$N17" = "3" ] && ok "add video17 控件 3/3 (无条件生效)" || bad "video17 控件 $N17/3"
v4l2loopback-ctl delete 17 2>/dev/null

echo "=== 4. selfheal 修复 (无 ordering cycle) ==="
grep -q 'PartOf' "$HOME/.config/systemd/user/ov5670-af-selfheal.service" && bad "PartOf 残留" || ok "PartOf 已去除"
systemctl --user is-active ov5670-af-selfheal.service | grep -q active && ok "selfheal active (无循环)" || bad "selfheal 异常"

echo "=== 5. 双服务 ==="
systemctl --user is-active ov5670-virtual-camera.service | grep -q active && ok "后摄 active" || bad "后摄异常"
systemctl --user is-active camera-enhancement.service | grep -q active && ok "前摄 active" || bad "前摄异常"

echo ""
echo "════════ 结果 ════════"
echo "PASS=$PASS FAIL=$FAIL (ad-hoc 验证, 非套件; 脚本保留 /tmp/hermes-verify-af-unconditional.sh 供复查)"
exit $FAIL
