#!/bin/bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# hermes-verify-af-finescan.sh — ad-hoc 验证 (2026-08-08 16:3x)
# 本回合改动: ①细扫轨迹固定基准 (fineScanStart_, 修漂移→范围外锁定)
# ②rescan limit 改细扫(围绕历史最佳, 不跳环节) ③confirm 回退 5 步
# ④历史全局最佳 bestFocusAll_ ⑤40s 锁定窗口(防回退打断细扫)
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
LOG=/tmp/ov5670-router.log
SVC=ov5670-virtual-camera.service

echo "=== 1. 编译 + 代码在位 ==="
cd "$PROJECT_ROOT"/back_camera/scripts
if gcc -O2 -Wall -o ov5670-router ov5670-router.c $(pkg-config --cflags --libs gstreamer-1.0) -lpthread 2>/tmp/afv3_cc.log; then
  [ "$(grep -cE 'error' /tmp/afv3_cc.log)" = "0" ] && ok "router 编译通过" || bad "编译错误"
else
  bad "编译失败"; echo "PASS=$PASS FAIL=$FAIL"; exit 1
fi
grep -q 'AF_AUTO_LOCK_SECONDS 40' ov5670-router.c && ok "锁定窗口 40s" || bad "窗口未改"
A=/tmp/libcamera-orig/src/src/ipa/ipu3/algorithms/af.cpp
grep -q 'fineScanStart_' $A && grep -q 'kCoarseSearchStep / 2' $A \
  && grep -q 'bestFocusAll_' $A && grep -q 'fine scan around' $A \
  && ok "IPA 修复全部在位 (固定轨迹/回退5步/历史最佳/rescan限细扫)" || bad "IPA 修复缺失"

echo "=== 2. 服务重启 ==="
systemctl --user restart $SVC
sleep 5
[ "$(systemctl --user is-active $SVC)" = "active" ] && ok "服务 active" || bad "服务未启动"

echo "=== 3. 触发 → 完整链路 ==="
timeout 18 v4l2-ctl -d /dev/video16 --stream-mmap --stream-count=250 > /dev/null 2>&1 &
sleep 4
grep -q '已激活 (cam PLAYING' "$LOG" && ok "reader 激活" || bad "未激活"
v4l2-ctl -d /dev/video16 --set-ctrl af_trigger=1; sleep 3; v4l2-ctl -d /dev/video16 --set-ctrl af_trigger=0
sleep 38
J() { journalctl --user -u $SVC --since "-90s" --no-pager 2>/dev/null; }
J | grep -q 'AF mode: 2 -> 1' && ok "AfMode 到达" || bad "AfMode 未到达"
J | grep -q 'AF coarse done' && ok "粗扫执行" || bad "粗扫未执行"
J | grep -qE 'fine scan around|AF locked at' && ok "细扫执行" || bad "细扫未执行"

echo "=== 4. 锁定位置在细扫范围内 (轨迹漂移修复的关键) ==="
LOCKED=$(J | grep 'AF locked at' | tail -1)
CENTER=$(J | grep -oE 'fine scan around [0-9]+' | tail -1 | grep -oE '[0-9]+')
[ -z "$CENTER" ] && CENTER=$(J | grep -oE 'AF peak confirmed at [0-9]+' | tail -1 | grep -oE '[0-9]+')
if [ -n "$LOCKED" ] && [ -n "$CENTER" ]; then
  LP=$(echo "$LOCKED" | grep -oE 'AF locked at [0-9]+' | grep -oE '[0-9]+')
  DELTA=$(( LP > CENTER ? LP - CENTER : CENTER - LP ))
  echo "  细扫中心=$CENTER, locked at=$LP, |delta|=$DELTA (范围±51)"
  [ "$DELTA" -le 51 ] && ok "锁定在细扫范围内 (漂移修复生效)" || bad "锁定超出范围 (漂移仍在)"
else
  bad "无法提取锁定/中心位置 (锁定未发生或未到40s)"
fi

echo "=== 5. 40s 回退 (锁定后回退, 不打断) ==="
sleep 15
J | grep -q 'AF mode: 1 -> 2' && ok "40s 回退 AfMode=2 到达" || bad "回退未到"
grep -q '回退 continuous' "$LOG" && ok "router 回退记录" || bad "router 回退缺失"

echo ""
echo "════════ 结果 ════════"
echo "PASS=$PASS FAIL=$FAIL (ad-hoc 验证, 非套件)"
exit $FAIL
