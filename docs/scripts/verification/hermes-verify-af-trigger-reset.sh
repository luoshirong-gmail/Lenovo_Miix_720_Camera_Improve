#!/bin/bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# hermes-verify-af-trigger-reset.sh — ad-hoc 验证 (2026-08-09 03:1x)
# 本回合改动: router 触发后自动写回 af_trigger=0 (int 控件不自动复位)
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
RTR="$PROJECT_ROOT"/back_camera/scripts/ov5670-router.c
LOG=/tmp/ov5670-router.log

echo "=== 1. 代码在位 ==="
grep -q 'set-ctrl af_trigger=0' $RTR && ok "自动写回代码在位" || bad "代码缺失"
grep -q '写回 0' $RTR && ok "注释说明在位" || bad "注释缺失"

echo "=== 2. 触发后自动回 0 行为 ==="
v4l2-ctl -d /dev/video16 --set-ctrl focus_auto=1 2>/dev/null
sleep 1
B=$(v4l2-ctl -d /dev/video16 --get-ctrl af_trigger 2>/dev/null | grep -oE '[01]$')
[ "$B" = "0" ] && ok "触发前 = 0" || bad "触发前 = $B (应 0)"
v4l2-ctl -d /dev/video16 --set-ctrl af_trigger=1
sleep 2
A=$(v4l2-ctl -d /dev/video16 --get-ctrl af_trigger 2>/dev/null | grep -oE '[01]$')
[ "$A" = "0" ] && ok "触发后 2s 自动回 0" || bad "触发后 = $A (未回 0)"
grep 'auto 触发扫描' $LOG | tail -1 | grep -q 'trigger=1' && ok "触发事件已处理 (trigger=1)" || bad "触发未处理"

echo "=== 3. 可重复触发 (0→1 边沿) ==="
N1=$(grep -c 'auto 触发扫描' $LOG)
v4l2-ctl -d /dev/video16 --set-ctrl af_trigger=1
sleep 2
N2=$(grep -c 'auto 触发扫描' $LOG)
[ "$N2" -gt "$N1" ] && ok "再次触发成功 ($N1→$N2)" || bad "无法再次触发 ($N1→$N2)"

echo "=== 4. 服务状态 ==="
systemctl --user is-active ov5670-virtual-camera.service | grep -q active && ok "服务 active" || bad "服务异常"

echo ""
echo "════════ 结果 ════════"
echo "PASS=$PASS FAIL=$FAIL (ad-hoc 验证, 非套件; 脚本保留 /tmp/hermes-verify-af-trigger-reset.sh 供复查)"
exit $FAIL
