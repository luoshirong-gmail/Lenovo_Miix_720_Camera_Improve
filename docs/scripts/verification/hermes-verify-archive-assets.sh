#!/bin/bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# hermes-verify-archive-assets.sh — ad-hoc 验证 (2026-08-08)
# 本回合改动: .gitignore (build-sources/backups 大文件排除规则)
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
ROOT="$PROJECT_ROOT"
cd $ROOT

echo "=== 1. .gitignore 新规则 ==="
git check-ignore back_camera/build-sources/libcamera-orig.tar.gz >/dev/null 2>&1 && ok "orig.tar.gz 排除" || bad "orig.tar.gz 未排除"
git check-ignore back_camera/build-sources/libcamera-vanilla.tar.gz >/dev/null 2>&1 && ok "vanilla.tar.gz 排除" || bad "vanilla.tar.gz 未排除"
git check-ignore back_camera/backups/ipa_ipu3.so.bak-9bcd5bbb >/dev/null 2>&1 && ok "IPA 备份排除" || bad "IPA 备份未排除"
git check-ignore back_camera/backups/libgstlibcamera.so.bak-1524 >/dev/null 2>&1 && ok "gst 备份排除" || bad "gst 备份未排除"
git check-ignore docs/ov5670-autofocus.md >/dev/null 2>&1 && bad "文档被误排除" || ok "文档未误排除"

echo "=== 2. 归档资产在位 (磁盘) ==="
[ -f back_camera/build-sources/libcamera-orig.tar.gz ] && ok "orig.tar.gz 磁盘在位 ($(du -sh back_camera/build-sources/libcamera-orig.tar.gz | cut -f1))" || bad "orig.tar.gz 缺失"
[ -f back_camera/build-sources/libcamera-vanilla.tar.gz ] && ok "vanilla.tar.gz 磁盘在位" || bad "vanilla.tar.gz 缺失"
[ -f back_camera/backups/ipa_ipu3.so.bak-9bcd5bbb ] && ok "IPA 备份在位" || bad "IPA 备份缺失"
[ -f back_camera/backups/libgstlibcamera.so.bak-1524 ] && ok "gst 备份在位" || bad "gst 备份缺失"

echo "=== 3. tar 完整性 (抽查关键文件) ==="
tar tzf back_camera/build-sources/libcamera-orig.tar.gz 2>/dev/null | grep -q 'ipa/ipu3/algorithms/af.cpp' && ok "orig.tar.gz 含 af.cpp" || bad "orig 缺 af.cpp"
tar tzf back_camera/build-sources/libcamera-vanilla.tar.gz 2>/dev/null | grep -q 'ipa/ipu3/algorithms/af.cpp' && ok "vanilla.tar.gz 含 af.cpp" || bad "vanilla 缺 af.cpp"

echo "=== 4. git 状态 ==="
git status --short | grep -q . && bad "有未提交变更: $(git status --short | wc -l)" || ok "工作区干净"
git log --oneline -1 | grep -q 'c0bf028' && ok "归档提交 c0bf028 在位" || bad "归档提交缺失"

echo ""
echo "════════ 结果 ════════"
echo "PASS=$PASS FAIL=$FAIL (ad-hoc 验证, 非套件)"
exit $FAIL
