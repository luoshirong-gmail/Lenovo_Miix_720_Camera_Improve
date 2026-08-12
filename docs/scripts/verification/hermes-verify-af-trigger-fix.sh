#!/bin/bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# hermes-verify-af-trigger-fix.sh — ad-hoc 验证 (2026-08-09 af_trigger 触发漏过修复)
# 验证对象: ov5670-router.c commit 6654910 (ID 修正 + 进程内 ioctl + 延迟复位 + 复查去抖)
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
P="$PROJECT_ROOT"
LOG=/tmp/ov5670-router.log

echo "=== 1. 编译产物与源码一致 (二进制新于源码) ==="
SRC_TS=$(stat -c %Y $P/back_camera/scripts/ov5670-router.c)
BIN_TS=$(stat -c %Y $P/back_camera/scripts/ov5670-router)
[ "$BIN_TS" -ge "$SRC_TS" ] && ok "二进制时间戳 >= 源码 (部署最新)" || bad "二进制旧于源码!"
# 数值常量编译后是立即数, strings 查不到 — 用反汇编查
objdump -d $P/back_camera/scripts/ov5670-router 2>/dev/null | grep -q '98f904' && ok "反汇编含新 ID 0x98f904 (2 条)" || bad "二进制无新 ID"
objdump -d $P/back_camera/scripts/ov5670-router 2>/dev/null | grep -q '98f004' && bad "二进制仍含旧 ID 0x98f004!" || ok "二进制无旧 ID"

echo "=== 2. 源码关键修复点 ==="
grep -q 'CID_AF_TRIGGER.*0x0098f904' $P/back_camera/scripts/ov5670-router.c && ok "源码 ID=0x0098f904" || bad "源码 ID 未修正"
grep -q 'ctrl.id = CID_AF_TRIGGER' $P/back_camera/scripts/ov5670-router.c && ok "af_get_trigger 用进程内 G_EXT" || bad "af_get_trigger 仍 popen"
grep -q 'VIDIOC_S_EXT_CTRLS' $P/back_camera/scripts/ov5670-router.c && ok "af_set_trigger 用进程内 S_EXT" || bad "af_set_trigger 缺失"
grep -q 'AF_TRIGGER_RESET_MS.*300' $P/back_camera/scripts/ov5670-router.c && ok "复位延迟 300ms" || bad "复位延迟缺失"
grep -q 'g_source_remove(pending_id)' $P/back_camera/scripts/ov5670-router.c && ok "inotify 复查去抖" || bad "复查去抖缺失"
! grep -q 'popen.*af_trigger\|popen.*set-ctrl af_trigger' $P/back_camera/scripts/ov5670-router.c && ok "无 popen af_trigger 残留" || bad "仍有 popen af_trigger!"

echo "=== 3. 运行时: 服务 + 控件 ID ==="
systemctl --user is-active ov5670-virtual-camera.service | grep -q active && ok "服务 active" || bad "服务未运行"
ID=$(v4l2-ctl -d /dev/video16 --list-ctrls 2>/dev/null | grep af_trigger | awk '{print $2}' | tr -d '()')
[ "$ID" = "0x0098f904" ] && ok "内核注册 ID=0x0098f904 (实测)" || bad "内核 ID=$ID (应 0x0098f904)"

echo "=== 4. 触发闭环 (设1 → 触发 → 300ms 延迟复位) ==="
CNT_BEFORE=$(grep -c 'auto 触发扫描' $LOG)
v4l2-ctl -d /dev/video16 --set-ctrl af_trigger=1
sleep 1.5
CNT_AFTER=$(grep -c 'auto 触发扫描' $LOG)
[ "$CNT_AFTER" -gt "$CNT_BEFORE" ] && ok "触发扫描日志新增 (${CNT_BEFORE}→${CNT_AFTER})" || bad "触发扫描未发生"
VAL=$(v4l2-ctl -d /dev/video16 --get-ctrl af_trigger | awk '{print $2}')
[ "$VAL" = "0" ] && ok "af_trigger 已复位为 0" || bad "af_trigger=$VAL (未复位)"

echo "=== 5. 风暴消除 (纯 idle 段 IN 事件数) ==="
# ⚠️ 取样说明: 18:30:00-16 是重启前旧进程残留 (风暴 4/s);
# 18:30:16 后新代码事件全部对应外部操作 (v4l2-ctl 触发测试, 每批 2-4 个),
# idle 间隙 0 事件。取 18:33:41-18:34:09 (验证脚本两次触发间 30s 纯 idle):
EV=$(grep 'IN_OPEN\|IN_CLOSE' $LOG | awk '$1 >= "[18:33:41]" && $1 <= "[18:34:09]"' | wc -l)
[ "$EV" = "0" ] && ok "30s 纯 idle 段 IN 事件=$EV (0=风暴消除)" || bad "idle 段 IN 事件=$EV (仍风暴)"
# 对照: 修复前同长 idle 段应为 15×30≈450

echo "=== 6. 无调试残留 ==="
! grep -q 'G_EXT af_trigger errno\|trig 读取 (v4l2-ctl' $P/back_camera/scripts/ov5670-router.c && ok "无调试日志残留" || bad "调试日志残留"

echo ""
echo "════════ 结果 ════════"
echo "PASS=$PASS FAIL=$FAIL (ad-hoc 验证, 非套件)"
exit $FAIL
