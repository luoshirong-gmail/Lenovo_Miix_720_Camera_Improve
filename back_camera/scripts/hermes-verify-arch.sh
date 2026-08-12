#!/bin/bash
# hermes-verify-arch: 架构版 IPA 部署前验证
# 机制: Awb 补偿 (yaml) + 独立 Ccm (标准 ccms 格式) + Bnr lut (yaml) — 两头标准
PASS=0; FAIL=0
ok()  { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

echo "=== 1. 编译产物 ==="
BUILD=/tmp/libcamera-orig/src/build-new/src/ipa/ipu3/ipa_ipu3.so
V=/tmp/ipa_ipu3_arch_std.so
if [ -f "$V" ] && [ -s "$V" ]; then ok "架构版 IPA 存在非空 ($(stat -c%s $V) B)"; else bad "IPA 缺失"; fi
if md5sum "$BUILD" "$V" | awk '{print $1}' | uniq -c | grep -q '^ *2 '; then ok "与 build 产物 md5 一致"; else bad "md5 不一致"; fi

echo "=== 2. 机制源码完整性 (ipu3/algorithms/) ==="
A=/tmp/libcamera-orig/src/src/ipa/ipu3/algorithms
[ -f "$A/ccm.h" ] && [ -f "$A/ccm.cpp" ] && ok "Ccm 独立算法存在 (ccm.h/cpp)" || bad "Ccm 缺失"
grep -q 'REGISTER_IPA_ALGORITHM(Ccm, "Ccm")' "$A/ccm.cpp" && ok "Ccm 注册" || bad "Ccm 未注册"
grep -q "'ccm.cpp'" "$A/meson.build" && ok "meson 注册 ccm.cpp" || bad "meson 缺 ccm.cpp"
grep -q 'tuningData\["ccms"\]' "$A/ccm.cpp" && ok "Ccm 读标准 ccms 格式" || bad "ccms 读取缺失"

echo "=== 3. Awb 机制 (yaml 补偿 + BNR lut) ==="
grep -q 'tuningData\["redCompensation"\]' "$A/awb.cpp" && ok "Awb redCompensation yaml" || bad "缺 redCompensation"
grep -q 'tuningData\["blueCompensation"\]' "$A/awb.cpp" && ok "Awb blueCompensation yaml" || bad "缺 blueCompensation"
grep -q 'bnr\["lut"\]' "$A/awb.cpp" && ok "Awb BNR lut yaml" || bad "缺 bnr.lut"
grep -q 'params->acc_param.bnr = bnr_' "$A/awb.cpp" && ok "BNR 用成员配置" || bad "bnr_ 未用"
grep -q 'acc_param.ccm' "$A/awb.cpp" && bad "awb.cpp 残留 CCM 填充 (应移交 Ccm 算法)" || ok "awb.cpp 无 CCM 残留"

echo "=== 4. 接口标准性 (intel-ipu3 uapi 对齐) ==="
grep -q 'kCcmFixedPoint = 8191' "$A/ccm.cpp" && ok "CCM 定点 8191=1.0 (uapi s16)" || bad "CCM 定点"
grep -q 'IPU3_UAPI_BNR_LUT_SIZE' "$A/awb.cpp" && ok "BNR lut 用 uapi 常量" || bad "BNR lut 常量"
grep -q 'coeff_m11\|coeff_m22\|coeff_m33' "$A/ccm.cpp" && ok "CCM 用 uapi 字段名" || bad "CCM 字段"

echo "=== 5. yaml (项目+系统) ==="
P="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tuning/ov5670.yaml"
S=/usr/share/libcamera/ipa/ipu3/ov5670.yaml
grep -q 'redCompensation: 1.15' "$P" && ok "项目 yaml 含 Awb 补偿" || bad "项目 yaml 缺补偿"
grep -q '  - Ccm:' "$P" && ok "项目 yaml 含 Ccm 段" || bad "项目 yaml 缺 Ccm"
if [ -f "$S" ]; then
  if grep -q '  - Ccm:' "$S" && grep -q 'redCompensation' "$S"; then
    ok "系统 yaml 已含新段"
  else
    echo "  ⏳ 系统 yaml 旧版 (待部署同步)"
  fi
fi

echo "=== 6. 回滚路径 ==="
ls /tmp/ipa_ipu3_backup_*.so >/dev/null 2>&1 && ok "回滚备份: $(ls /tmp/ipa_ipu3_backup_*.so | tr '\n' ' ')" || bad "无备份"

echo ""
echo "════════ 结果 ════════"
echo "PASS=$PASS FAIL=$FAIL (ad-hoc 验证, 非套件)"
echo "⚠️ 逻辑验证 (yaml→acc_param 生效链路) 阻塞: 需 sudo 部署 + 日志确认 — 不自动判定"
[ $FAIL -eq 0 ]
