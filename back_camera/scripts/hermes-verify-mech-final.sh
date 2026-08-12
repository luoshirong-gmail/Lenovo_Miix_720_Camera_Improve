#!/bin/bash
# hermes-verify-mech-final: 机制开发最终静态验证 (不重启服务)
# 覆盖本轮全部改动: ccm.cpp 修复 / yaml 干净状态 / 服务文件清理 / 工具链 / 收尾脚本
PASS=0; FAIL=0
ok()  { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

echo "=== 1. ccm.cpp 3x3 解析修复 (已部署) ==="
A=/tmp/libcamera-orig/src/src/ipa/ipu3/algorithms
if grep -q 'asList 迭代逐行解析' "$A/ccm.cpp"; then ok "ccm.cpp 含嵌套列表修复"; else bad "ccm.cpp 缺修复"; fi
SYS=/usr/lib/x86_64-linux-gnu/libcamera/ipa/ipa_ipu3.so
B=/tmp/libcamera-orig/src/build-new/src/ipa/ipu3/ipa_ipu3.so
V=/tmp/ipa_ipu3_arch_std.so
if [ -f "$SYS" ] && md5sum "$SYS" "$B" "$V" 2>/dev/null | awk '{print $1}' | sort -u | wc -l | grep -q '^1$'; then
  ok "系统 IPA = build = 归档 (md5 三方一致)"
else
  bad "md5 不一致: sys=$(md5sum $SYS 2>/dev/null|cut -d' ' -f1) build=$(md5sum $B 2>/dev/null|cut -d' ' -f1) arch=$(md5sum $V 2>/dev/null|cut -d' ' -f1)"
fi

echo "=== 2. yaml 干净状态 ==="
Y="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tuning/ov5670.yaml"
grep -q 'redCompensation: 1.15' "$Y" && ok "Awb 补偿保留" || bad "Awb 补偿丢失"
grep -q '  - Ccm:' "$Y" && ok "Ccm 段在" || bad "Ccm 段丢失"
grep -qE '^\s*ccms:' "$Y" && bad "测试 ccms 残留!" || ok "无测试 ccms 残留 (注释示例除外)"
grep -qE '^\s*bnr:' "$Y" && bad "测试 bnr 残留!" || ok "无测试 bnr 残留 (注释示例除外)"
python3 -c "import yaml,sys; yaml.safe_load(open('$Y')); print('  ✅ yaml 语法有效')" 2>/dev/null || bad "yaml 语法错误"

echo "=== 3. 服务文件 (清理后) ==="
SVC="$HOME/.config/systemd/user/ov5670-virtual-camera.service"
grep -q 'LIBCAMERA_IPU3_TUNING_FILE' "$SVC" && ok "tuning env 保留" || bad "tuning env 丢失"
grep -q 'LIBCAMERA_LOG_LEVELS' "$SVC" && bad "Debug 日志未移除!" || ok "Debug 日志已移除"
systemctl --user show ov5670-virtual-camera.service -p ActiveState --no-pager | grep -q 'ActiveState=active' && ok "服务当前 active" || bad "服务非 active"

echo "=== 4. 工具链 ==="
C="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/calibration"
python3 -c "import ast; ast.parse(open('$C/analyze.py').read()); print('  ✅ analyze.py 语法有效')"
bash -n "$C/capture.sh" && ok "capture.sh 语法有效" || bad "capture.sh 语法错误"
[ -x "$C/analyze.py" ] && [ -x "$C/capture.sh" ] && ok "工具可执行" || bad "工具缺执行位"

echo "=== 5. 收尾脚本 ==="
bash -n "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/deploy-finalize.sh" && ok "deploy-finalize.sh 语法有效" || bad "收尾脚本语法错误"

echo ""
echo "════════ 结果 ════════"
echo "PASS=$PASS FAIL=$FAIL (ad-hoc 静态验证 — 不涉及服务重启/部署)"
echo "⚠️ 最终部署验证 (服务文件生效 + 系统 yaml 同步) 按用户安排: 等用户在场执行 deploy-finalize.sh"
[ $FAIL -eq 0 ]
