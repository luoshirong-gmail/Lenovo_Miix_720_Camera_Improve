#!/bin/bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# hermes-verify-multiscan-fix.sh — ad-hoc 验证 (2026-08-09 晚)
# 本回合变更 (commit fa2cd1f): manual→auto 多轮全扫修复
#   ① 撤销补丁③ (locked_ idle 循环重扫)
#   ② rescan 不再全范围重扫 (confirm 失败直接 fine scan 历史最佳)
#   ③ IPA 重编译安装 (md5 5cd09862)
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
A="$PROJECT_ROOT"/back_camera/patched-sources/ipu3-ipa/af.cpp

echo "=== 1. 循环扫描补丁已撤销 (代码层) ==="
! grep -q 'locked idle timeout, rescan' "$A" && ok "locked idle 循环已撤销" || bad "循环补丁仍存在"
grep -q '循环扫描修复' "$A" && ok "撤销注释在位" || bad "缺撤销注释"

echo "=== 2. rescan 不再全扫 (代码层) ==="
grep -q '多轮全扫修复' "$A" && ok "多轮全扫修复注释在位" || bad "缺注释"
# 原 rescan 分支 (forceScan_=true 重新全扫) 应已移除 — 只保留 startAutoScan(539) 的启动粗扫
RESCAN_FS=$(sed -n '640,690p' "$A" | grep -c 'forceScan_ = true')
[ "$RESCAN_FS" = "0" ] && ok "rescan 分支无 forceScan 全扫 (仅 539 行 startAutoScan 保留)" || bad "rescan 分支仍有全扫 ($RESCAN_FS)"
grep -q 'AF rescan (' "$A" && ok "新 rescan 日志 (直接 fine scan)" || bad "缺新日志"

echo "=== 3. IPA 已重编译安装 (运行时) ==="
MD5=$(md5sum /usr/lib/x86_64-linux-gnu/libcamera/ipa/ipa_ipu3.so | cut -d' ' -f1)
[ "$MD5" = "5cd098629d74e99008571d6ff1a25774" ] && ok "系统 IPA = 新编译版 (5cd09862)" || bad "IPA 未更新 ($MD5)"

echo "=== 4. 服务 + 触发闭环 ==="
systemctl --user is-active ov5670-virtual-camera.service | grep -q active && ok "服务 active" || bad "服务异常"
# fresh 触发
v4l2-ctl -d /dev/video16 --set-ctrl focus_absolute=600 2>&1
sleep 0.8
v4l2-ctl -d /dev/video16 --set-ctrl focus_auto=1 2>&1
sleep 1
grep -E 'auto 触发扫描' /tmp/ov5670-router.log | tail -1 | grep -q 'focus_auto=1' && ok "触发成功" || bad "未触发"

echo "=== 5. 多轮全扫已消除 (IPA 日志采样 30s) ==="
S1=$(journalctl --since "30 sec ago" --no-pager 2>/dev/null | grep -c 'AF auto scan start')
sleep 30
S2=$(journalctl --since "30 sec ago" --no-pager 2>/dev/null | grep -c 'AF auto scan start')
echo "  (信息) 30s 窗口 AF auto scan start: $S2 次 — 触发后应≤1 (初始粗扫), 无循环"
# 关键: 修复后 rescan 路径应显示 'AF rescan (N), fine scan around' (直接 fine scan)
journalctl --since "2 min ago" --no-pager 2>/dev/null | grep -qE 'AF rescan \([0-9]+\), fine scan around' && ok "rescan 直接转 fine scan (新逻辑)" || bad "未见新 rescan 日志"

echo ""
echo "════════ 结果 ════════"
echo "PASS=$PASS FAIL=$FAIL (ad-hoc 验证, 非套件)"
exit $FAIL
