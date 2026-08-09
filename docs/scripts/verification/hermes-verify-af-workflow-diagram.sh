#!/bin/bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# hermes-verify-af-workflow-diagram.sh — ad-hoc 验证 (2026-08-09)
# 验证对象: docs/ov5670-autofocus-workflow.html (对焦工作原理图, commit 06603b8)
# 检查: 三层结构完整性 / 关键实体与控件 ID / 时间线常量与源码一致性 / continuous A 方案语义 / HTML 结构
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
P="$PROJECT_ROOT"
F=$P/docs/ov5670-autofocus-workflow.html
C=$P/back_camera/scripts/ov5670-router.c

echo "=== 1. 文件存在且非空 ==="
[ -s "$F" ] && ok "文件存在 ($(stat -c %s $F) 字节)" || bad "文件缺失或为空!"

echo "=== 2. 三层结构完整性 ==="
grep -q '① 实体层 ENTITIES' "$F" && ok "实体层标题" || bad "实体层缺失"
grep -q '② 事件层 EVENTS' "$F" && ok "事件层标题" || bad "事件层缺失"
grep -q '③ 时间线层 TIMELINE' "$F" && ok "时间线层标题" || bad "时间线层缺失"

echo "=== 3. 关键实体与控件 ID (与源码/内核一致) ==="
grep -q '0x0098F904' "$F" && ok "af_trigger ID=0x0098F904 (实测值)" || bad "af_trigger ID 错误"
grep -q '0x009A090C' "$F" && ok "focus_auto ID=0x009A090C" || bad "focus_auto ID 缺失"
grep -q '0x009A090A' "$F" && ok "focus_abs ID=0x009A090A" || bad "focus_abs ID 缺失"
grep -q 'ov5670-router' "$F" && ok "router 实体" || bad "router 实体缺失"
grep -q 'libcamerasrc' "$F" && ok "libcamerasrc 实体" || bad "libcamerasrc 缺失"
grep -q 'applyControls' "$F" && ok "libcamera 管线实体" || bad "管线缺失"
grep -q 'IPU3Af' "$F" && ok "IPA 实体" || bad "IPA 缺失"
grep -q 'VCM' "$F" && ok "VCM 实体" || bad "VCM 缺失"

echo "=== 4. 三条触发路径 ==="
grep -q '路径 A — MANUAL' "$F" && ok "路径 A (manual)" || bad "路径 A 缺失"
grep -q '路径 B — AUTO' "$F" && ok "路径 B (auto)" || bad "路径 B 缺失"
grep -q '路径 C — CONTINUOUS' "$F" && ok "路径 C (continuous)" || bad "路径 C 缺失"

echo "=== 5. 时间线常量与源码一致性 ==="
# 300ms 延迟复位
SRC_RESET=$(grep -oP 'AF_TRIGGER_RESET_MS \K[0-9]+' $C | head -1)
grep -q '300ms' "$F" && ok "图含 300ms 延迟复位 (源码 AF_TRIGGER_RESET_MS=$SRC_RESET)" || bad "300ms 缺失"
[ "$SRC_RESET" = "300" ] && ok "源码复位常量=300 一致" || bad "源码复位常量=$SRC_RESET (≠300)"
# 500/1000/1500ms 跨帧重发
grep -q '500/1000/1500' "$F" && ok "图含 500/1000/1500ms 跨帧重发" || bad "跨帧重发缺失"
# 40s 回退
SRC_LOCK=$(grep -oP 'AF_AUTO_LOCK_SECONDS \K[0-9]+' $C | head -1)
grep -q '40s' "$F" && ok "图含 40s 锁定回退 (源码 AF_AUTO_LOCK_SECONDS=$SRC_LOCK)" || bad "40s 缺失"
[ "$SRC_LOCK" = "40" ] && ok "源码锁定常量=40 一致" || bad "源码锁定常量=$SRC_LOCK (≠40)"
# 扫描步进 粗20/细2
grep -q '粗扫 (全范围) → 峰值确认 → 细扫 → 锁定' "$F" && ok "扫描链顺序 粗→确认→细" || bad "扫描链顺序错误"
# 2s auto 心跳
grep -q '心跳' "$F" && ok "心跳机制标注" || bad "心跳缺失"
# 200ms manual 心跳
grep -q '200ms' "$F" && ok "manual 心跳 200ms" || bad "200ms 缺失"

echo "=== 6. continuous 语义与 A 方案源码一致 (用户指出 hill climbing 错误) ==="
grep -q 'continuous: 统一复用 auto 链' "$F" && ok "图: continuous 统一复用 auto 链" || bad "图: continuous 描述错误"
grep -q '弃 hill climbing' "$F" && ok "图: 标注弃 hill climbing (历史对照)" || bad "图: 缺弃用标注"
grep -q '失焦检测 → 全范围重扫' "$F" && ok "图: continuous 失焦重扫语义" || bad "图: 缺失焦重扫"
grep -q '已锁定则保留焦点不重扫' "$F" && ok "图: 回退保留焦点不重扫" || bad "图: 缺回退保留语义"
AFS=$P/back_camera/patched-sources/ipu3-ipa/af.cpp
[ -f "$AFS" ] && grep -q 'default: /\* 2: continuous' "$AFS" && ok "A 方案源码存在 (patched-sources)" || bad "A 方案源码缺失"
grep -q 'autoScanCoarse(context)' "$AFS" && ok "源码: continuous 分支走 autoScanCoarse" || bad "源码: continuous 未走 auto 链"
grep -q 'startAutoScan(context)' "$AFS" && ok "源码: 失焦 → startAutoScan" || bad "源码: 缺 startAutoScan"
strings /usr/lib/x86_64-linux-gnu/libcamera/ipa/ipa_ipu3.so 2>/dev/null | grep -q 'startAutoScan' && ok "系统 IPA 含 startAutoScan 符号 (A 方案已装)" || bad "系统 IPA 无 A 方案符号"
md5sum /usr/lib/x86_64-linux-gnu/libcamera/ipa/ipa_ipu3.so | grep -q '4cbd1e0b' && ok "系统 IPA md5=4cbd1e0b (A 方案版)" || bad "IPA md5 不符"

echo "=== 7. 核心竞态与修复标注 ==="
grep -q 'merge+clear' "$F" && ok "竞态标注 (merge+clear)" || bad "竞态标注缺失"
grep -q '2026-08-09' "$F" && ok "修复日期标注" || bad "修复日期缺失"
grep -q '0x98f004' "$F" && ok "旧 ID 对照标注 (0x98f004)" || bad "旧 ID 对照缺失"

echo "=== 8. HTML 结构完整性 ==="
# 标签配对 (粗检)
OPEN=$(grep -o '<svg' "$F" | wc -l); CLOSE=$(grep -o '</svg>' "$F" | wc -l)
[ "$OPEN" = "1" ] && [ "$CLOSE" = "1" ] && ok "SVG 标签配对 (1/1)" || bad "SVG 标签异常 ($OPEN/$CLOSE)"
grep -q '</html>' "$F" && ok "HTML 闭合" || bad "HTML 未闭合"
grep -q 'viewBox' "$F" && ok "viewBox 存在" || bad "viewBox 缺失"

echo ""
echo "════════ 结果 ════════"
echo "PASS=$PASS FAIL=$FAIL (ad-hoc 验证, 非套件)"
exit $FAIL
