#!/bin/bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# hermes-verify-af-reliability.sh — ad-hoc 验证 (2026-08-08)
# 本回合改动: ①跨帧重发×3(触发) ②心跳直发(auto) ③回退重发×3+continuous心跳
# ④IPA idle 兜底 ⑤kMaxChange=0.3 ⑥confirmPeak_=false ⑦rescanCount_ 上限
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
LOG=/tmp/ov5670-router.log
SVC=ov5670-virtual-camera.service

echo "=== 1. 编译 + 修复代码在位 ==="
cd "$PROJECT_ROOT"/back_camera/scripts
if gcc -O2 -Wall -o ov5670-router ov5670-router.c $(pkg-config --cflags --libs gstreamer-1.0) -lpthread 2>/tmp/afv2_cc.log; then
  [ "$(grep -cE 'error' /tmp/afv2_cc.log)" = "0" ] && ok "router 编译通过" || bad "编译错误"
else
  bad "编译失败"; echo "PASS=$PASS FAIL=$FAIL"; exit 1
fi
grep -q 'af_auto_retry_cb' ov5670-router.c && grep -q 'af_auto_fallback_cb' ov5670-router.c \
  && grep -q 'continuous 心跳' ov5670-router.c \
  && ok "跨帧重发+回退重发+continuous心跳 代码在位" || bad "修复代码缺失"
grep -q 'kMaxChange = 0.3' /tmp/libcamera-orig/src/src/ipa/ipu3/algorithms/af.cpp \
  && ok "IPA kMaxChange=0.3 在位" || bad "kMaxChange 缺失"
grep -q 'autoIdleFrames_' /tmp/libcamera-orig/src/src/ipa/ipu3/algorithms/af.cpp \
  && ok "IPA idle 兜底在位" || bad "idle 兜底缺失"

echo "=== 2. 服务重启 ==="
systemctl --user restart $SVC
sleep 5
[ "$(systemctl --user is-active $SVC)" = "active" ] && ok "服务 active" || bad "服务未启动"

echo "=== 3. 激活 + 触发 → AfMode 到达 + 扫描 ==="
timeout 15 v4l2-ctl -d /dev/video16 --stream-mmap --stream-count=200 > /dev/null 2>&1 &
sleep 4
grep -q '已激活 (cam PLAYING' "$LOG" && ok "reader 激活" || bad "未激活"
v4l2-ctl -d /dev/video16 --set-ctrl af_trigger=1; sleep 3; v4l2-ctl -d /dev/video16 --set-ctrl af_trigger=0
sleep 24
J() { journalctl --user -u $SVC --since "-50s" --no-pager 2>/dev/null; }
J | grep -q 'AF mode: 2 -> 1' && ok "AfMode 到达 IPA" || bad "AfMode 未到达"
J | grep -qE 'AF trigger received|AF auto idle timeout' \
  && ok "触发生效 (AfTrigger 或 idle 兜底)" || bad "触发未生效"
J | grep -qE 'AF auto scan start|AF coarse done' && ok "扫描执行" || bad "扫描未执行"
J | grep -qE 'AF peak confirmed|rescan limit reached' \
  && ok "峰值确认或重扫上限" || bad "确认/上限未见"

echo "=== 4. 30s 回退 → continuous 恢复 ==="
sleep 25
grep -q '回退 continuous' "$LOG" && ok "router 30s 回退" || bad "回退未触发"
sleep 8
J2() { journalctl --user -u $SVC --since "-25s" --no-pager 2>/dev/null; }
J2 | grep -q 'AF mode: 1 -> 2' && ok "回退 AfMode=2 到达 IPA" || bad "回退 AfMode 未到"
J2 | grep -q 'Variance change' && ok "continuous 失焦检测恢复" || bad "continuous 未恢复"

echo ""
echo "════════ 结果 ════════"
echo "PASS=$PASS FAIL=$FAIL (ad-hoc 验证, 非套件)"
exit $FAIL
