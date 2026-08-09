#!/bin/bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# hermes-verify-af-v3.sh — ad-hoc 验证 (2026-08-09 03:0x)
# 本回合改动: ①af.cpp v3 参数 (粗扫 20 / 细扫 2) ②router focus_auto=0 → manual
# ③系统 IPA 重编译安装 (7a6663dd)
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
AF="$PROJECT_ROOT"/back_camera/patched-sources/ipu3-ipa/af.cpp
RTR="$PROJECT_ROOT"/back_camera/scripts/ov5670-router.c
LOG=/tmp/ov5670-router.log

echo "=== 1. v3 参数 ==="
grep -q 'kCoarseSearchStep = 20' $AF && ok "粗扫步进 = 20" || bad "粗扫步进错误"
grep -q 'kFineSearchStep = 2' $AF && ok "细扫步进 = 2" || bad "细扫步进错误"
grep -q 'kFineRange = 0.05' $AF && ok "细扫范围 ±51 保持 (覆盖粗扫偏差 ±20)" || bad "细扫范围错误"

echo "=== 2. 系统 IPA (v3 重编译) ==="
md5sum /usr/lib/x86_64-linux-gnu/libcamera/ipa/ipa_ipu3.so | grep -q '7a6663dd' && ok "系统 IPA = v3 (7a6663dd)" || bad "IPA 版本不符"
systemctl --user is-active ov5670-virtual-camera.service | grep -q active && ok "服务 active" || bad "服务异常"
[ "$(v4l2-ctl -d /dev/video16 --list-ctrls 2>/dev/null | grep -cE 'af_trigger|focus_auto|focus_absolute')" = "3" ] && ok "对焦控件 3 个在位" || bad "控件缺失"

echo "=== 3. manual 接口 (focus_auto=0) ==="
v4l2-ctl -d /dev/video16 --set-ctrl focus_auto=0
sleep 1
grep 'manual 模式 (focus_auto=0)' $LOG | tail -1 | grep -q . && ok "focus_auto=0 → manual (router 日志)" || bad "manual 接口未触发"
grep -q 'manual 模式 (focus_auto=0)' $RTR && ok "接口代码在位" || bad "代码缺失"

echo "=== 4. auto 触发 (focus_auto=1) ==="
v4l2-ctl -d /dev/video16 --set-ctrl focus_auto=1
sleep 1
grep 'auto 触发扫描' $LOG | tail -1 | grep -q . && ok "focus_auto=1 → auto 触发" || bad "auto 触发未生效"

echo "=== 5. focus_absolute → manual (原有路径) ==="
v4l2-ctl -d /dev/video16 --set-ctrl focus_absolute=400
sleep 1
grep 'manual focus_absolute=400' $LOG | tail -1 | grep -q . && ok "focus_absolute 拖动 → manual" || bad "拖动路径失效"

echo ""
echo "════════ 结果 ════════"
echo "PASS=$PASS FAIL=$FAIL (ad-hoc 验证, 非套件; 脚本保留 /tmp/hermes-verify-af-v3.sh 供复查)"
exit $FAIL
