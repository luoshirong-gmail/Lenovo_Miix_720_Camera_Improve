#!/bin/bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# hermes-verify-af-manual-switch.sh — ad-hoc 验证 (2026-08-09 12:2x)
# 本回合修复: 手动切回 focus_auto 可靠触发 (写回竞态 + 拖动轮误触发)
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
LOG=/tmp/ov5670-router.log

echo "=== 1. 代码修复在位 ==="
grep -q 'af_manual_active)' "$PROJECT_ROOT"/back_camera/scripts/ov5670-router.c && ok "② 触发条件含 af_manual_active" || bad "② 条件缺失"
grep -q 'auto_on_event && !manual_event' "$PROJECT_ROOT"/back_camera/scripts/ov5670-router.c && ok "拖动轮跳过 ② (manual_event)" || bad "manual_event 缺失"
grep -q 'TEMP-DBG' "$PROJECT_ROOT"/back_camera/scripts/ov5670-router.c && bad "调试日志残留" || ok "无调试日志"

echo "=== 2. 拖动轮不误触发 ==="
# 设 auto → 拖 focus_absolute → 检查拖轮无 auto 触发
v4l2-ctl -d /dev/video16 --set-ctrl focus_auto=1 2>/dev/null; sleep 1
BEFORE=$(grep -c 'auto 触发扫描' $LOG)
v4l2-ctl -d /dev/video16 --set-ctrl focus_absolute=450 2>/dev/null; sleep 2
AFTER_DRAG=$(grep -c 'auto 触发扫描' $LOG)
DRAG_CNT=$(grep 'manual focus_absolute=450' $LOG | wc -l)
[ "$AFTER_DRAG" = "$BEFORE" ] && ok "拖动轮无 auto 触发 (manual=$DRAG_CNT)" || bad "拖动轮误触发 (before=$BEFORE after=$AFTER_DRAG)"

echo "=== 3. 写回 focus_auto=0 ==="
v4l2-ctl -d /dev/video16 --get-ctrl focus_auto 2>/dev/null | grep -q '0' && ok "拖动后写回 focus_auto=0" || bad "写回失败"

echo "=== 4. 勾选触发 (场景 A: 手动状态勾选) ==="
v4l2-ctl -d /dev/video16 --set-ctrl focus_auto=1 2>/dev/null; sleep 3
grep 'auto 触发扫描' $LOG | tail -1 | grep -q "$(date +%H:%M)" && ok "勾选触发 auto" || bad "勾选未触发"

echo "=== 5. 场景 B (focus_auto=0 → 勾选) ==="
v4l2-ctl -d /dev/video16 --set-ctrl focus_auto=0 2>/dev/null; sleep 2
BEFORE=$(grep -c 'auto 触发扫描' $LOG)
v4l2-ctl -d /dev/video16 --set-ctrl focus_auto=1 2>/dev/null; sleep 3
AFTER=$(grep -c 'auto 触发扫描' $LOG)
[ "$AFTER" -gt "$BEFORE" ] && ok "场景 B 触发" || bad "场景 B 未触发"

echo "=== 6. 服务/控件 ==="
systemctl --user is-active ov5670-virtual-camera.service | grep -q active && ok "后摄 active" || bad "后摄异常"
N=$(v4l2-ctl -d /dev/video16 --list-ctrls 2>/dev/null | grep -cE 'af_trigger|focus_auto|focus_absolute')
[ "$N" = "3" ] && ok "控件 3/3" || bad "控件 $N/3"

echo ""
echo "════════ 结果 ════════"
echo "PASS=$PASS FAIL=$FAIL (ad-hoc 验证, 非套件; 脚本保留 /tmp/hermes-verify-af-manual-switch.sh 供复查)"
exit $FAIL
