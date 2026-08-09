#!/bin/bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# hermes-verify-focus-auto-writeback.sh — ad-hoc 验证 (2026-08-09 04:0x)
# 本回合改动 (router): ①拖 focus_absolute 写回 focus_auto=0 (状态一致)
# ③加 !af_manual_active (防写回误触发停心跳)
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
ROOT="$PROJECT_ROOT"/back_camera/scripts
RTR=$ROOT/ov5670-router.c
LOG=/tmp/ov5670-router.log
G() { v4l2-ctl -d /dev/video16 --get-ctrl "$1" 2>/dev/null | grep -oE '[0-9]+$'; }

echo "=== 1. 编译 ==="
cd $ROOT
gcc -O2 -Wall -o /tmp/ov5670-router-t ov5670-router.c $(pkg-config --cflags --libs gstreamer-1.0) -lpthread 2>/tmp/wb_cc.log
[ $? -eq 0 ] && ok "编译成功" || bad "编译失败"
rm -f /tmp/ov5670-router-t

echo "=== 2. 代码在位 ==="
grep -q 'set-ctrl focus_auto=0' $RTR && ok "① 写回 focus_auto=0 在位" || bad "写回代码缺失"
grep -q '!af_manual_active' $RTR && ok "③ 防误触发条件在位" || bad "③ 条件缺失"

echo "=== 3. 行为: 拖 focus_absolute → focus_auto 写回 0 ==="
v4l2-ctl -d /dev/video16 --set-ctrl focus_auto=1 2>/dev/null
sleep 1
V=$(G focus_absolute)
NV=$((V + 1 > 1023 ? V - 1 : V + 1))
v4l2-ctl -d /dev/video16 --set-ctrl focus_absolute=$NV
sleep 2
A=$(G focus_auto)
[ "$A" = "0" ] && ok "拖动后 focus_auto=0" || bad "写回失败 (=$A)"
grep "manual focus_absolute=$NV" $LOG | tail -1 | grep -q . && ok "manual 响应" || bad "manual 未响应"

echo "=== 4. 行为: 勾选 focus_auto (0→1) → 自动触发 ==="
N1=$(grep -c 'auto 触发扫描' $LOG)
v4l2-ctl -d /dev/video16 --set-ctrl focus_auto=1
sleep 2
N2=$(grep -c 'auto 触发扫描' $LOG)
[ "$N2" -gt "$N1" ] && ok "勾选自动触发 auto ($N1→$N2)" || bad "未自动触发 ($N1→$N2)"

echo "=== 5. 系统状态 ==="
systemctl --user is-active ov5670-virtual-camera.service | grep -q active && ok "服务 active" || bad "服务异常"
[ "$(v4l2-ctl -d /dev/video16 --list-ctrls 2>/dev/null | grep -cE 'af_trigger|focus_auto|focus_absolute')" = "3" ] && ok "控件 3 个" || bad "控件缺失"

echo ""
echo "════════ 结果 ════════"
echo "PASS=$PASS FAIL=$FAIL (ad-hoc 验证, 非套件; 脚本保留 /tmp/hermes-verify-focus-auto-writeback.sh 供复查)"
exit $FAIL
