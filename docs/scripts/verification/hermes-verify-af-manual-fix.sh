#!/bin/bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# hermes-verify-af-manual-fix.sh — ad-hoc 验证 (2026-08-09 03:2x)
# 本回合改动: router af_apply_manual_heartbeat 加 af-mode=0 直发
# (修复: focus_auto=0 后拖 focus_absolute 镜头不动 — IPA 停留
#  continuous 忽略 LensPosition)
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
ROOT="$PROJECT_ROOT"/back_camera/scripts
RTR=$ROOT/ov5670-router.c
LOG=/tmp/ov5670-router.log

echo "=== 1. 编译 (0 error) ==="
cd $ROOT
gcc -O2 -Wall -o /tmp/ov5670-router-test ov5670-router.c $(pkg-config --cflags --libs gstreamer-1.0) -lpthread 2>/tmp/afv8_cc.log
RC=$?
[ $RC -eq 0 ] && ok "编译成功" || bad "编译失败 (rc=$RC)"
grep -c 'error:' /tmp/afv8_cc.log | grep -q '^0$' && ok "0 error" || bad "$(grep 'error:' /tmp/afv8_cc.log | head -2)"
rm -f /tmp/ov5670-router-test

echo "=== 2. 代码在位 (心跳含 af-mode=0) ==="
grep -A3 'af_apply_manual_heartbeat' $RTR | grep -q 'af_set_src_int("af-mode", 0)' && ok "心跳直发 af-mode=0 在位" || bad "代码缺失"
grep -q 'clear 竞争丢弃' $RTR && ok "修复注释在位" || bad "注释缺失"

echo "=== 3. 服务与控件 ==="
systemctl --user is-active ov5670-virtual-camera.service | grep -q active && ok "服务 active" || bad "服务异常"
[ "$(v4l2-ctl -d /dev/video16 --list-ctrls 2>/dev/null | grep -cE 'af_trigger|focus_auto|focus_absolute')" = "3" ] && ok "对焦控件 3 个" || bad "控件缺失"

echo "=== 4. focus_auto=0 → manual (行为) ==="
v4l2-ctl -d /dev/video16 --set-ctrl focus_auto=0
sleep 1
grep 'manual 模式 (focus_auto=0)' $LOG | tail -1 | grep -q . && ok "focus_auto=0 → manual" || bad "manual 未触发"

echo "=== 5. 拖动 focus_absolute → manual 响应 + 心跳 af-mode=0 ==="
v4l2-ctl -d /dev/video16 --set-ctrl focus_absolute=300
sleep 2
grep 'manual focus_absolute=300' $LOG | tail -1 | grep -q . && ok "拖动 → manual 响应" || bad "拖动未响应"
grep 'AF: af-mode=0' $LOG | tail -1 | grep -q . && ok "心跳直发 af-mode=0 (日志实证)" || bad "心跳无 af-mode=0"

echo "=== 6. 恢复 auto ==="
v4l2-ctl -d /dev/video16 --set-ctrl focus_auto=1
sleep 1
grep 'auto 触发扫描' $LOG | tail -1 | grep -q . && ok "focus_auto=1 → auto 恢复" || bad "auto 未恢复"

echo ""
echo "════════ 结果 ════════"
echo "PASS=$PASS FAIL=$FAIL (ad-hoc 验证, 非套件; 脚本保留 /tmp/hermes-verify-af-manual-fix.sh 供复查)"
exit $FAIL
