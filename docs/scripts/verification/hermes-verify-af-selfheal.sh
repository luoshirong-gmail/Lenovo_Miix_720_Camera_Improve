#!/bin/bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# hermes-verify-af-selfheal.sh — ad-hoc 验证 (2026-08-09 04:1x, 2026-08-09 晚更新)
# 本回合: 第三次重启控件丢失 → 诊断 (模块内容正确/ec-fix 未重载/
# delete+add 自愈可行) → 实施 ov5670-af-selfheal (开机自动重建)
# ⚠️ 2026-08-09 晚: selfheal 已禁用 (版本统一后控件注册确定性, 双保险无必要)
# 本节断言改为验证"已禁用"状态, 防止误认为双保险仍在兜底
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
SELF="$PROJECT_ROOT"/back_camera/scripts/ov5670-af-selfheal.sh

echo "=== 1. 控件恢复 (本回合核心) ==="
N=$(v4l2-ctl -d /dev/video16 --list-ctrls 2>/dev/null | grep -cE 'af_trigger|focus_auto|focus_absolute')
[ "$N" = "3" ] && ok "video16 对焦控件 3/3" || bad "控件 $N/3"

echo "=== 2. selfheal 已禁用 (2026-08-09 晚: 版本统一后双保险移除) ==="
systemctl --user is-enabled ov5670-af-selfheal.service | grep -q disabled && ok "selfheal 服务已禁用" || bad "服务未禁用"
systemctl --user is-active ov5670-af-selfheal.service | grep -q inactive && ok "selfheal 未运行" || bad "服务仍在运行"
[ -f ~/.config/systemd/user/ov5670-af-selfheal.service ] && ok "服务文件保留 (供参考)" || bad "服务文件被删"

echo "=== 3. selfheal 逻辑 ==="
grep -q 'grep -q .af_trigger.' $SELF && ok "检测 af_trigger" || bad "检测逻辑缺失"
grep -q 'v4l2loopback-ctl delete 16' $SELF && ok "delete 16" || bad "delete 缺失"
grep -q 'v4l2loopback-ctl add -n' $SELF && ok "add 重建" || bad "add 缺失"
grep -q 'systemctl --user stop ov5670-virtual-camera' $SELF && ok "停后摄服务" || bad "stop 缺失"

echo "=== 4. 正常路径幂等 (控件在, 不动作) ==="
rm -f /tmp/ov5670-selfheal.log
$SELF
grep -q '无需处理' /tmp/ov5670-selfheal.log && ok "正常路径无操作" || bad "正常路径异常"

echo "=== 5. 双服务 + 模块 ==="
systemctl --user is-active ov5670-virtual-camera.service | grep -q active && ok "后摄 active" || bad "后摄异常"
systemctl --user is-active camera-enhancement.service | grep -q active && ok "前摄 active" || bad "前摄异常"
# 模块版本基准: 2026-08-09 晚 dkms --force 重建 (base 统一 0xf900), 时间戳 20:55
ls -la /lib/modules/$(uname -r)/updates/dkms/v4l2loopback.ko.zst | grep -q '20:55' && ok "模块 20:55 (base=0xf900 重建版)" || bad "模块时间异常"

echo ""
echo "════════ 结果 ════════"
echo "PASS=$PASS FAIL=$FAIL (ad-hoc 验证, 非套件; 脚本保留 /tmp/hermes-verify-af-selfheal.sh 供复查)"
exit $FAIL
