#!/bin/bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# hermes-verify-af-official-model.sh — ad-hoc 验证 (2026-08-09 晚)
# 本回合变更 (commit 608f2b6): AF 切换逻辑按官方模型重做
#   router: focus_auto 驱动 AfMode 0/2, 移除心跳/回退/状态标志
#   af.cpp: 切入 continuous 不立即扫描 (先失焦判断), manual 切入不清零
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
P="$PROJECT_ROOT"
R=$P/back_camera/scripts/ov5670-router.c
A=$P/back_camera/patched-sources/ipu3-ipa/af.cpp

echo "=== 1. 官方模型代码层 (router) ==="
grep -q 'focus_auto=0 → AfMode=0' $R && ok "状态机注释: manual" || bad "缺 manual 注释"
grep -q 'focus_auto=1 → AfMode=2' $R && ok "状态机注释: continuous" || bad "缺 continuous 注释"
! grep -q 'AF_AUTO_LOCK_SECONDS\|AF_AUTO_HB_MS\|AF_MANUAL_HB_MS' $R && ok "心跳/回退常量已移除" || bad "旧常量残留"
! grep -q 'af_manual_active\|af_auto_active' $R && ok "状态标志已移除" || bad "状态标志残留"
! grep -q 'af_auto_fallback_cb' $R && ok "回退回调已移除" || bad "回退回调残留"
grep -q 'AF_SINGLE_SCAN_MS' $R && ok "单次对焦参数在位" || bad "缺单次对焦参数"

echo "=== 2. 官方模型代码层 (af.cpp) ==="
grep -q '切入 continuous \*\*不立即' $A && ok "continuous 不立即扫描注释" || bad "缺注释"
grep -q '不 afReset 归零' $A && ok "manual 不清零注释" || bad "缺 manual 注释"
! grep -q 'locked idle timeout, rescan' $A && ok "无循环扫描残留" || bad "循环补丁残留"

echo "=== 3. 运行时: IPA 新版本 + 服务 ==="
MD5=$(md5sum /usr/lib/x86_64-linux-gnu/libcamera/ipa/ipa_ipu3.so | cut -d' ' -f1)
[ "$MD5" = "f02048f87c9432df26f068819bc8c08e" ] && ok "系统 IPA = f02048f8 (官方模型版)" || bad "IPA 未更新 ($MD5)"
systemctl --user is-active ov5670-virtual-camera.service | grep -q active && ok "服务 active" || bad "服务异常"

echo "=== 4. 触发闭环 + 模式切换 ==="
# 当前状态
FA=$(v4l2-ctl -d /dev/video16 --get-ctrl focus_auto 2>/dev/null)
echo "  (信息) 当前 focus_auto=$FA"
# manual → continuous 切换
v4l2-ctl -d /dev/video16 --set-ctrl focus_auto=0 2>&1
sleep 0.5
grep -E 'manual 模式' /tmp/ov5670-router.log | tail -1 | grep -q '保持当前焦点' && ok "1→manual: 保持焦点" || bad "manual 切换异常"
# manual 拖移镜
v4l2-ctl -d /dev/video16 --set-ctrl focus_absolute=400 2>&1
sleep 0.5
grep -E 'manual focus_absolute=400' /tmp/ov5670-router.log | tail -1 | grep -q '400' && ok "manual 移镜 400" || bad "移镜异常"
# 单次对焦
v4l2-ctl -d /dev/video16 --set-ctrl af_trigger=1 2>&1
sleep 0.5
grep -E '单次对焦触发' /tmp/ov5670-router.log | tail -1 | grep -q '触发' && ok "单次对焦触发" || bad "未触发"
sleep 6
grep -E '扫描完成 → 回 manual' /tmp/ov5670-router.log | tail -1 | grep -q '回 manual' && ok "扫描完成回 manual" || bad "未回 manual"
# af_trigger 复位 (v4l2-ctl 输出带前缀 "af_trigger: 0")
AT=$(v4l2-ctl -d /dev/video16 --get-ctrl af_trigger 2>/dev/null | awk '{print $NF}')
[ "$AT" = "0" ] && ok "af_trigger 已复位 ($AT)" || bad "af_trigger=$AT"

echo "=== 5. 无循环扫描 (扫描链计数) ==="
N=$(journalctl --since "10 min ago" --no-pager 2>/dev/null | grep -cE 'IPU3Af.*(fine scan around|confirm failed)')
[ "$N" -le 4 ] && ok "扫描链事件=$N (≤4, 无循环)" || bad "扫描链事件=$N (可能循环)"

echo ""
echo "════════ 结果 ════════"
echo "PASS=$PASS FAIL=$FAIL (ad-hoc 验证, 非套件)"
exit $FAIL
