#!/bin/bash
# install_af.sh — OV5670 后置摄像头对焦优化安装脚本 (2026-08-08 全新重做)
#
# 安全设计 (用户明确要求, 旧版教训):
#   - 全部交互式 sudo, 严禁密码文件/管道传密
#   - 幂等: 补丁/安装可重复执行
#   - 协同: v4l2loopback 重载影响前摄 video99 → 停/启两个服务
#   - 行为验证: 控件出现 / af-trigger 属性 / 扫描
#
# 2026-08-08 修复 (用户实测反馈):
#   ① dkms build 必须 --force (补丁改源码后 "already built, skip" 是旧产物)
#   ② 删除手动 sign-file — dkms 自动签名已生效 (系统 MOK key, 已验证)
#   ③ systemctl --user 在 sudo 下连不上 user bus → 自动转 SUDO_USER 的 bus
#
# 用法: bash install_af.sh [install|uninstall|status]
#   (普通用户执行即可: patch 阶段脚本内部 sudo; 服务操作用 --user)
set -u

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$PROJ_DIR/scripts"
AF_PATCH="$SCRIPTS/patch_v4l2loopback_af.py"
V4L2_SRC="/usr/src/v4l2loopback-0.15.4"
# ⚠️ 构建产物路径: IPA/GST 的 .so 需先编译 (meson build), 按实际构建目录修改
# 修改版源码归档: back_camera/patched-sources/ (比对/排查用)
IPA_SRC="/tmp/libcamera-orig/src/build-new/src/ipa/ipu3/ipa_ipu3.so"
IPA_DST="/usr/lib/x86_64-linux-gnu/libcamera/ipa/ipa_ipu3.so"
GST_SRC="/tmp/libcamera-orig/src/build-new/src/gstreamer/libgstlibcamera.so"
GST_DST="/usr/lib/x86_64-linux-gnu/gstreamer-1.0/libgstlibcamera.so"

# --- systemctl --user 兼容: sudo 下转真实用户的 user bus ---
if [ "$(id -u)" = "0" ]; then
    _SUDO_USER="${SUDO_USER:-heavenflyer}"
    _UID="$(id -u "$_SUDO_USER" 2>/dev/null || echo 1000)"
    UCTL() { sudo -u "$_SUDO_USER" env XDG_RUNTIME_DIR="/run/user/$_UID" \
             DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$_UID/bus" \
             systemctl --user "$@"; }
else
    UCTL() { systemctl --user "$@"; }
fi

echo "════════ OV5670 对焦优化安装 ════════"

status() {
    echo "--- 1. v4l2loopback 对焦控件补丁 (源码) ---"
    python3 "$AF_PATCH" check
    echo "--- 2. 模块签名 ---"
    modinfo v4l2loopback 2>/dev/null | grep -E 'signer' | head -1
    echo "--- 3. IPA (ipa_ipu3.so) ---"
    ls -la "$IPA_DST" 2>/dev/null | awk '{print "  " $5 " bytes"}'
    echo "--- 4. gst 插件 ---"
    ls -la "$GST_DST" 2>/dev/null | awk '{print "  " $5 " bytes"}'
    echo "--- 5. libcamerasrc af-trigger 属性 ---"
    n=$(gst-inspect-1.0 libcamerasrc 2>/dev/null | grep -c 'af-trigger')
    echo "  af-trigger 属性: $n 个匹配 $([ "$n" -ge 1 ] && echo '✅' || echo '❌')"
    echo "--- 6. video16 对焦控件 (模块生效验证) ---"
    n=$(v4l2-ctl -d /dev/video16 --list-ctrls 2>/dev/null | grep -ciE 'focus')
    echo "  focus 控件: $n 个 $([ "$n" -ge 3 ] && echo '✅' || echo '❌ (模块未重编译/未重载)')"
}

install() {
    echo ""
    echo "════ 阶段 1: v4l2loopback 对焦控件补丁 (源码) ════"
    sudo python3 "$AF_PATCH" apply

    echo ""
    echo "════ 阶段 2: dkms 强制重编译 (--force) + 自动签名 ════"
    echo "> sudo dkms build --force (需要认证)"
    sudo dkms build -m v4l2loopback -v 0.15.4 --force 2>&1 | tail -4 || { echo "❌ dkms build 失败"; exit 1; }
    echo "> 验证模块已含补丁 (strings)"
    KO="$(find /var/lib/dkms/v4l2loopback -name 'v4l2loopback.ko' | head -1)"
    if [ -n "$KO" ] && strings "$KO" 2>/dev/null | grep -q 'af_trigger'; then
        echo "  ✅ 模块已含 af_trigger 控件"
    else
        echo "  ⚠️ 未在 .ko 检出 af_trigger (zst 压缩产物则继续, 安装后验证)"
    fi
    echo "> sudo dkms install (dkms 自动签名: 系统 MOK key)"
    sudo dkms install -m v4l2loopback -v 0.15.4 --force 2>&1 | tail -3 || { echo "❌ dkms install 失败"; exit 1; }
    modinfo v4l2loopback 2>/dev/null | grep -E 'signer' | head -1

    echo ""
    echo "════ 阶段 3: 重载模块 (协同停服务) ════"
    echo "> 停止两个相机服务 (video16/video99 依赖此模块)"
    UCTL stop ov5670-virtual-camera.service 2>&1 | tail -1
    UCTL stop camera-enhancement.service 2>&1 | tail -1
    sleep 2
    echo "> sudo rmmod + modprobe"
    if ! sudo rmmod v4l2loopback 2>&1 | tail -2; then
        echo "  ⚠️ rmmod 失败 (模块仍被占用) — 重试前确认无进程持有 video16/video99"
        fuser -v /dev/video16 /dev/video99 2>&1 | tail -3
        exit 1
    fi
    sudo modprobe v4l2loopback 2>&1 | tail -2 || { echo "❌ modprobe 失败 (检查 modprobe.d)"; exit 1; }
    sleep 2
    echo "> 重建设备 + 重启服务"
    [ -x "$PROJ_DIR/scripts/ov5670-ensure-device.sh" ] && bash "$PROJ_DIR/scripts/ov5670-ensure-device.sh"
    UCTL restart ov5670-virtual-camera.service 2>&1 | tail -1
    UCTL restart camera-enhancement.service 2>&1 | tail -1
    sleep 5
    UCTL is-active ov5670-virtual-camera.service camera-enhancement.service

    echo ""
    echo "════ 阶段 4: IPA (ipa_ipu3.so) ════"
    if [ -f "$IPA_SRC" ]; then
        echo "> sudo 安装 ipa_ipu3.so (签名验证接口存在但非强制; 保留原 .sign)"
        sudo cp "$IPA_SRC" "$IPA_DST"
        ls -la "$IPA_DST" | awk '{print "  ✅ " $5 " bytes"}'
    else
        echo "  ⚠️ $IPA_SRC 不存在 — 先编译 libcamera (P2)"
    fi

    echo ""
    echo "════ 阶段 5: gst 插件 (libgstlibcamera.so) ════"
    if [ -f "$GST_SRC" ]; then
        echo "> sudo 安装 libgstlibcamera.so"
        sudo cp "$GST_SRC" "$GST_DST"
        ls -la "$GST_DST" | awk '{print "  ✅ " $5 " bytes"}'
    else
        echo "  ⚠️ $GST_SRC 不存在 — 先编译 libcamera (P3)"
    fi

    echo ""
    echo "════ 阶段 6: 重启 router (加载新 gst 插件) ════"
    UCTL restart ov5670-virtual-camera.service 2>&1 | tail -1
    sleep 5
    UCTL is-active ov5670-virtual-camera.service

    echo ""
    echo "════ 验证 ════"
    status
}

uninstall() {
    echo "════ 卸载 ════"
    UCTL stop ov5670-virtual-camera.service camera-enhancement.service 2>&1 | tail -1
    sudo python3 "$AF_PATCH" revert
    sudo dkms build -m v4l2loopback -v 0.15.4 --force 2>&1 | tail -2
    sudo dkms install -m v4l2loopback -v 0.15.4 --force 2>&1 | tail -2
    sudo rmmod v4l2loopback 2>/dev/null
    sudo modprobe v4l2loopback 2>/dev/null
    UCTL restart ov5670-virtual-camera.service camera-enhancement.service 2>&1 | tail -1
    echo "(IPA/gst 插件还原请用: sudo apt reinstall libcamera-ipa gstreamer1.0-libcamera)"
}

case "${1:-status}" in
    install) install ;;
    uninstall) uninstall ;;
    status) status ;;
    *) echo "用法: $0 [install|uninstall|status]"; exit 1 ;;
esac
