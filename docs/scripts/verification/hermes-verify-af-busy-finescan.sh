#!/bin/bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# hermes-verify-af-busy-finescan.sh — ad-hoc 验证 (2026-08-08 16:5x)
# 本回合改动: ①S_FMT busy 等待 (IN_CLOSE 释放→重启, 60s 兜底)
# ②细扫固定轨迹基准 (修范围外锁定) ③rescan limit→细扫 ④40s 锁定窗口
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
LOG=/tmp/ov5670-router.log
SVC=ov5670-virtual-camera.service
R="$PROJECT_ROOT"/back_camera/scripts/ov5670-router.c

echo "=== 1. 编译 + busy 等待代码在位 ==="
cd "$PROJECT_ROOT"/back_camera/scripts
if gcc -O2 -Wall -o ov5670-router ov5670-router.c $(pkg-config --cflags --libs gstreamer-1.0) -lpthread 2>/tmp/afv4_cc.log; then
  [ "$(grep -cE ' error' /tmp/afv4_cc.log)" = "0" ] && ok "router 编译通过" || bad "编译错误"
else
  bad "编译失败"; echo "PASS=$PASS FAIL=$FAIL"; exit 1
fi
grep -q 'strstr(err->message, "is busy")' $R && grep -q 'af_busy_wait' $R \
  && grep -q '60000, af_busy_timeout_cb' $R && ok "busy 等待代码在位 (检测/标志/60s兜底)" \
  || bad "busy 代码缺失"
grep -q 'IN_CLOSE) && af_busy_wait' $R && ok "IN_CLOSE 释放检测在位" || bad "IN_CLOSE 缺失"
grep -q 'fineScanStart_' /tmp/libcamera-orig/src/src/ipa/ipu3/algorithms/af.cpp \
  && ok "细扫固定轨迹在位" || bad "细扫轨迹缺失"

echo "=== 2. 服务稳定 ==="
systemctl --user restart $SVC
sleep 5
ST=$(systemctl --user is-active $SVC)
[ "$ST" = "active" ] && ok "服务 active" || bad "服务: $ST"
sleep 8
[ "$(systemctl --user is-active $SVC)" = "active" ] && ok "13s 后仍 active (无重启循环)" || bad "服务抖动"
echo "  重启计数: $(systemctl --user show $SVC -p NRestarts | cut -d= -f2)"

echo "=== 3. 对焦链路 (触发→扫描→锁定→40s回退, reader 覆盖全程) ==="
timeout 42 v4l2-ctl -d /dev/video16 --stream-mmap --stream-count=600 > /dev/null 2>&1 &
sleep 4
grep -q '已激活 (cam PLAYING' "$LOG" && ok "reader 激活" || bad "未激活"
v4l2-ctl -d /dev/video16 --set-ctrl af_trigger=1; sleep 3; v4l2-ctl -d /dev/video16 --set-ctrl af_trigger=0
sleep 38
J() { journalctl --user -u $SVC --since "-100s" --no-pager 2>/dev/null; }
J | grep -q 'AF mode: 2 -> 1' && ok "AfMode 到达" || bad "AfMode 未达"
J | grep -q 'AF coarse done' && ok "粗扫执行" || bad "粗扫未执行"
LOCKED=$(J | grep 'AF locked at' | tail -1)
CENTER=$(J | grep -oE 'fine scan around [0-9]+' | tail -1 | grep -oE '[0-9]+')
[ -z "$CENTER" ] && CENTER=$(J | grep -oE 'AF peak confirmed at [0-9]+' | tail -1 | grep -oE '[0-9]+')
if [ -n "$LOCKED" ] && [ -n "$CENTER" ]; then
  LP=$(echo "$LOCKED" | grep -oE 'AF locked at [0-9]+' | grep -oE '[0-9]+')
  DELTA=$(( LP > CENTER ? LP - CENTER : CENTER - LP ))
  echo "  细扫中心=$CENTER locked=$LP |Δ|=$DELTA (≤51)"
  [ "$DELTA" -le 51 ] && ok "锁定在细扫范围内" || bad "锁定超范围"
else
  bad "锁定/中心未提取"
fi
sleep 10
J | grep -q 'AF mode: 1 -> 2' && ok "40s 回退到达" || bad "回退未达"
J | grep -q 'Variance change' && ok "continuous 恢复" || bad "continuous 未恢复"

echo ""
echo "════════ 结果 ════════"
echo "PASS=$PASS FAIL=$FAIL (ad-hoc 验证, 非套件; busy 等待运行时触发待真实占用场景)"
exit $FAIL
