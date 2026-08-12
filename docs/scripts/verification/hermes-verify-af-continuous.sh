#!/bin/bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# hermes-verify-af-continuous.sh — ad-hoc 验证 (2026-08-08 17:0x)
# 本回合 continuous 修复: ①方差归一化 var/mean² (抗 AE 增益)
# ②diff_var uint32→double (截断 bug) ③自适应基准 max 跟随 cur
# ④扫描后基准收敛期 ⑤kMaxChange 0.4 ⑥失焦连续 5 帧确认
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
LOG=/tmp/ov5670-router.log
SVC=ov5670-virtual-camera.service
A=/tmp/libcamera-orig/src/src/ipa/ipu3/algorithms/af.cpp

echo "=== 1. 编译 + 修复代码在位 ==="
cd "$PROJECT_ROOT"/back_camera/scripts
gcc -O2 -Wall -o ov5670-router ov5670-router.c $(pkg-config --cflags --libs gstreamer-1.0) -lpthread 2>/tmp/afv5_cc.log
[ "$(grep -cE ' error' /tmp/afv5_cc.log)" = "0" ] && ok "router 编译通过" || bad "router 编译错误"
cd /tmp/libcamera-orig/src/build-new
ninja src/ipa/ipu3/ipa_ipu3.so 2>&1 | grep -cE ' error' | grep -q '^0$' && ok "IPA 编译通过" || bad "IPA 编译错误"
grep -q 'var_sum / y_items.size() / (mean \* mean)' $A && ok "方差归一化在位" || bad "归一化缺失"
grep -q 'const double diff_var' $A && ok "diff_var double (截断修复)" || bad "diff_var 未改"
grep -q '0.95 \* context.activeState.af.maxVariance' $A && ok "自适应基准在位" || bad "自适应基准缺失"
grep -q 'kBaselineFrames' $A && ok "基准收敛期在位" || bad "收敛期缺失"
grep -q 'kMaxChange = 0.4' $A && ok "阈值 0.4" || bad "阈值错误"
grep -q 'kOutOfFocusConfirmFrames' $A && ok "失焦 5 帧确认" || bad "确认帧缺失"

echo "=== 2. 服务重启 + 稳定 ==="
systemctl --user restart $SVC
sleep 5
[ "$(systemctl --user is-active $SVC)" = "active" ] && ok "服务 active" || bad "服务未启动"

echo "=== 3. continuous 静止稳定性 (reader 30s, 0 误判重扫) ==="
timeout 35 v4l2-ctl -d /dev/video16 --stream-mmap --stream-count=500 > /dev/null 2>&1 &
sleep 6
grep -q '已激活 (cam PLAYING' "$LOG" && ok "reader 激活" || bad "未激活"
sleep 20
J() { journalctl --user -u $SVC --since "-75s" --no-pager 2>/dev/null; }
OOF=$(J | grep -c 'out-of-focus confirmed')
RSCAN=$(J | grep -c 'Previous step')
echo "  失焦确认=$OOF 重扫=$RSCAN"
[ "$OOF" = "0" ] && ok "静止期零失焦误判" || bad "失焦误判 $OOF 次"
[ "$RSCAN" = "0" ] && ok "静止期零重扫" || bad "重扫 $RSCAN 次"
RATE=$(J | grep 'Variance change' | tail -1 | grep -oE 'rate: [0-9.]+' | grep -oE '[0-9.]+')
echo "  最新 rate=$RATE (应 < 0.4)"
[ -n "$RATE" ] && awk "BEGIN{exit !($RATE < 0.4)}" && ok "rate 低于阈值 (稳定)" || bad "rate 超阈值"

echo "=== 4. auto 链路 (触发→扫描→锁定→回退→continuous 恢复) ==="
v4l2-ctl -d /dev/video16 --set-ctrl af_trigger=1; sleep 3; v4l2-ctl -d /dev/video16 --set-ctrl af_trigger=0
sleep 46
J | grep -q 'AF mode: 2 -> 1' && ok "AfMode 到达" || bad "AfMode 未达"
J | grep -q 'AF coarse done' && ok "粗扫执行" || bad "粗扫未执行"
J | grep -q 'AF locked at' && ok "细扫锁定" || bad "锁定未发生"
J | grep -q 'AF mode: 1 -> 2' && ok "40s 回退到达" || bad "回退未达"
RATE2=$(J | grep 'Variance change' | tail -1 | grep -oE 'rate: [0-9.]+' | grep -oE '[0-9.]+')
echo "  回退后 rate=$RATE2 (continuous 恢复)"
[ -n "$RATE2" ] && awk "BEGIN{exit !($RATE2 < 0.4)}" && ok "回退后 continuous 稳定" || bad "回退后不稳定"

echo ""
echo "════════ 结果 ════════"
echo "PASS=$PASS FAIL=$FAIL (ad-hoc 验证, 非套件; 真失焦运行时触发待真实场景变化)"
exit $FAIL
