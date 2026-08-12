#!/bin/bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# hermes-verify-af-continuous-unified.sh — ad-hoc 验证 (2026-08-09 03:4x)
# 本回合改动 (af.cpp):
# ①A 方案: continuous 复用 auto 扫描链 (forceScan_/confirmPeak_/fineScan_ → auto 链)
# ②auto→continuous 回退保留对焦状态 (locked_ 时不 afReset, 不重扫)
# ③autoScanFine 完成加基准收敛期 (防 continuous 直接进失焦检测误判)
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
AF="$PROJECT_ROOT"/back_camera/patched-sources/ipu3-ipa/af.cpp

echo "=== 1. A 方案: continuous 走 auto 链 ==="
grep -A6 'default: /\* 2: continuous' $AF | grep -q 'forceScan_' && ok "continuous 分支识别 forceScan_" || bad "continuous 分支缺 forceScan_"
grep -A6 'default: /\* 2: continuous' $AF | grep -q 'autoScanCoarse' && ok "forceScan_ → autoScanCoarse" || bad "缺 autoScanCoarse"
grep -A20 'default: /\* 2: continuous' $AF | grep -q 'startAutoScan(context);' && ok "失焦确认 → startAutoScan (不再 hill climbing)" || bad "失焦未走 auto 链"
grep -A20 'default: /\* 2: continuous' $AF | grep -q 'afReset(context)' && bad "continuous 仍调 afReset (旧路径残留)" || ok "无 afReset 残留"

echo "=== 2. 回退保留 (auto→continuous 不重扫) ==="
grep -B2 -A8 'mode == controls::AfModeContinuous' $AF | grep -q 'locked_' && ok "回退保留判断 (locked_)" || bad "缺 locked_ 判断"
grep -A8 'mode == controls::AfModeContinuous' $AF | grep -q 'baselineFrames_ = kBaselineFrames' && ok "回退保留后加基准收敛期" || bad "缺 baselineFrames_"
grep -A8 'mode == controls::AfModeContinuous' $AF | grep -q 'afReset(context);' && ok "未锁定路径仍 afReset (初始扫描)" || bad "未锁定路径异常"

echo "=== 3. 细扫完成加基准收敛期 ==="
grep -B2 -A2 'baselineFrames_ = kBaselineFrames' $AF | grep -q 'AF locked' && ok "autoScanFine 完成设 baselineFrames_" || bad "缺 baselineFrames_ 设置"

echo "=== 4. 系统状态 ==="
md5sum /usr/lib/x86_64-linux-gnu/libcamera/ipa/ipa_ipu3.so | grep -q '4cbd1e0b' && ok "系统 IPA = 新编译 (4cbd1e0b)" || bad "IPA 版本不符"
systemctl --user is-active ov5670-virtual-camera.service | grep -q active && ok "服务 active" || bad "服务异常"
[ "$(v4l2-ctl -d /dev/video16 --list-ctrls 2>/dev/null | grep -cE 'af_trigger|focus_auto|focus_absolute')" = "3" ] && ok "对焦控件 3 个" || bad "控件缺失"

echo ""
echo "════════ 结果 ════════"
echo "PASS=$PASS FAIL=$FAIL (ad-hoc 验证, 非套件; 脚本保留 /tmp/hermes-verify-af-continuous-unified.sh 供复查)"
exit $FAIL
