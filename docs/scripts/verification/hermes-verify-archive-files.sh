#!/bin/bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# hermes-verify-archive-files.sh — ad-hoc 验证 (2026-08-08)
# 验证对象: ①.gitignore (发布标准排除规则) ②install_af.sh (路径注释修正)
# 本脚本保留供复查 (不清理)
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
ROOT="$PROJECT_ROOT"
IG=$ROOT/.gitignore
IA=$ROOT/back_camera/scripts/install_af.sh

echo "=== 1. install_af.sh (语法 + 结构) ==="
bash -n "$IA" 2>/dev/null && ok "bash 语法 OK" || bad "bash 语法错误"
grep -q 'PROJ_DIR' "$IA" && ok "PROJ_DIR 定义在位" || bad "PROJ_DIR 缺失"
grep -q 'IPA_SRC=' "$IA" && grep -q 'GST_SRC=' "$IA" && ok "构建产物变量在位" || bad "变量缺失"
grep -q 'patched-sources' "$IA" && ok "patched-sources 引用注释在位" || bad "注释缺失"
grep -q 'install|uninstall|status' "$IA" && ok "用法说明 (install/uninstall/status)" || bad "用法说明缺失"

echo "=== 2. install_af.sh status 模式 (只读运行) ==="
OUT=$(bash "$IA" status 2>&1 | head -8)
RC=$?
echo "$OUT" | head -3
[ $RC -eq 0 ] && ok "status 模式正常退出" || bad "status 退出码 $RC"

echo "=== 3. .gitignore (语法 + 排除生效) ==="
cd $ROOT
[ -f "$IG" ] && ok ".gitignore 在位" || bad "缺失"
git check-ignore back_camera/scripts/ov5670-router >/dev/null 2>&1 && ok "编译二进制被排除" || bad "二进制未排除"
git check-ignore docs/archive/keep.bin >/dev/null 2>&1 && ok "大 bin 被排除" || bad "bin 未排除"
git check-ignore __pycache__/x.pyc >/dev/null 2>&1 && ok "__pycache__ 被排除" || bad "pycache 未排除"
git check-ignore docs/ov5670-autofocus.md >/dev/null 2>&1 && bad "文档被误排除" || ok "文档未误排除"

echo ""
echo "════════ 结果 ════════"
echo "PASS=$PASS FAIL=$FAIL (ad-hoc 验证, 非套件; 脚本保留 /tmp/hermes-verify-archive-files.sh 供复查)"
exit $FAIL
