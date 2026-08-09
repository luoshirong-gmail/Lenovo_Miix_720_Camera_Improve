#!/bin/bash
# hermes-verify-modprobe-load.sh — ad-hoc 验证 (2026-08-09 05:1x)
# 本回合根治: v4l2loopback 改由 modprobe 命令加载 (v4l2loopback-load.service)
# 替代 systemd-modules-load (kmod 库, add 控件不注册 0/3)
# ⚠️ 第六轮补充 (9c5dd11): 最终方案还含 sudo update-initramfs -u —
#    initramfs 打包旧 modules-load.d → initrd 阶段预加载 → root 阶段改动
#    无效; 更新后 initramfs 内 modules-load.d 为注释版 (initrd 不再加载)。
#    验证: sudo lsinitramfs /boot/initrd.img-$(uname -r) | grep -i v4l2loopback
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }

echo "=== 1. 加载服务部署 ==="
sudo systemctl is-enabled v4l2loopback-load.service 2>/dev/null | grep -q enabled && ok "v4l2loopback-load.service enabled" || bad "服务未启用"
grep -q 'ExecStart=.*modprobe v4l2loopback' /etc/systemd/system/v4l2loopback-load.service && ok "ExecStart=modprobe v4l2loopback" || bad "ExecStart 异常"
grep -q '^# v4l2loopback' /etc/modules-load.d/ov5670-virtual-camera.conf && ok "modules-load.d 已注释 v4l2loopback" || bad "modules-load.d 未注释"

echo "=== 2. 当前模块 (modprobe 加载) ==="
echo "  video_nr: $(cat /sys/module/v4l2loopback/parameters/video_nr 2>/dev/null)"
ls /sys/module/v4l2loopback/parameters/ 2>/dev/null | grep -q video_nr && ok "模块已加载" || bad "模块未加载"

echo "=== 3. add 注册 (决定性: modprobe 加载 → 3/3) ==="
v4l2loopback-ctl add -n "OV5670 Test" -w 3840 -h 2160 -b 16 -x 0 17 2>/dev/null
sleep 1
N17=$(v4l2-ctl -d /dev/video17 --list-ctrls 2>/dev/null | grep -cE 'af_trigger|focus_auto|focus_absolute')
[ "$N17" = "3" ] && ok "add video17 控件 3/3 (modprobe 加载生效)" || bad "video17 控件 $N17/3"
v4l2loopback-ctl delete 17 2>/dev/null

echo "=== 4. 服务状态 ==="
systemctl --user is-active ov5670-virtual-camera.service | grep -q active && ok "后摄 active" || bad "后摄异常"
systemctl --user is-active camera-enhancement.service | grep -q active && ok "前摄 active" || bad "前摄异常"
N=$(v4l2-ctl -d /dev/video16 --list-ctrls 2>/dev/null | grep -cE 'af_trigger|focus_auto|focus_absolute')
[ "$N" = "3" ] && ok "video16 控件 3/3" || bad "video16 控件 $N/3"

echo ""
echo "════════ 结果 ════════"
echo "PASS=$PASS FAIL=$FAIL (ad-hoc 验证, 非套件; 脚本保留 /tmp/hermes-verify-modprobe-load.sh 供复查)"
exit $FAIL
