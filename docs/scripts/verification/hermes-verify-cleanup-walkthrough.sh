#!/bin/bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# hermes-verify-cleanup-walkthrough.sh — ad-hoc 验证 (2026-08-08 18:0x)
# 完整走查第三轮: 调试痕迹清理 (sF 待办) 验证
# 本脚本保留供复查 (不清理)
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
SVC_FILE="$HOME/.config/systemd/user/ov5670-virtual-camera.service"
TPL="$PROJECT_ROOT"/back_camera/scripts/ov5670-virtual-camera.service
GST=/usr/lib/x86_64-linux-gnu/gstreamer-1.0/libgstlibcamera.so
CLEAN_GST=/tmp/libgstlibcamera.so.bak-1524

echo "=== 1. 服务文件 (部署) ==="
grep -q 'Environment' "$SVC_FILE" 2>/dev/null && bad "仍有 Environment (调试变量)" || ok "无 Environment (调试变量已移除)"
diff <(grep -vE '^\s*#' "$SVC_FILE") <(grep -vE '^\s*#' "$TPL") >/dev/null 2>&1 && ok "部署 = 归档模板 (完全一致)" || bad "部署与模板有差异"
systemctl --user is-active ov5670-virtual-camera.service | grep -q active && ok "服务 active" || bad "服务异常"

echo "=== 2. gst 插件 (干净版) ==="
[ -f "$GST" ] && [ "$(stat -c%s "$GST")" = "$(stat -c%s "$CLEAN_GST")" ] && ok "插件 = 干净版 ($(stat -c%s "$GST") B)" || bad "插件大小不符"
CUR=$(systemctl --user show ov5670-virtual-camera.service -p ActiveEnterTimestamp | cut -d= -f2)
N=$(journalctl --user -u ov5670-virtual-camera.service --since "$CUR" --no-pager 2>/dev/null | grep -c 'AFDBG')
[ "$N" = "0" ] && ok "当前实例 AFDBG=0 (无调试日志)" || bad "AFDBG=$N 条"

echo "=== 3. 功能完整性 (插件还原后) ==="
v4l2-ctl -d /dev/video16 --list-ctrls 2>/dev/null | grep -q 'af_trigger' && ok "af_trigger 控件在位" || bad "af_trigger 缺失"
v4l2-ctl -d /dev/video16 --info 2>/dev/null | grep -q 'OV5670 Back Camera' && ok "video16 正常" || bad "video16 异常"

echo "=== 4. 系统配置 ==="
grep -q 'relativeLuminanceTarget' /usr/share/libcamera/ipa/ipu3/ov5670.yaml && ok "系统 tuning 生效 (AGC target 0.35)" || bad "tuning 缺失"
grep -h 'exclusive_caps=0' /etc/modprobe.d/*.conf 2>/dev/null | grep -q . && ok "v4l2loopback exclusive_caps=0" || bad "exclusive_caps 配置缺失"
systemctl --user is-active camera-enhancement.service | grep -q active && ok "前摄增强服务 active" || bad "前摄服务异常"

echo ""
echo "════════ 结果 ════════"
echo "PASS=$PASS FAIL=$FAIL (ad-hoc 验证, 非套件; 脚本保留 /tmp/hermes-verify-cleanup-walkthrough.sh 供复查)"
exit $FAIL
