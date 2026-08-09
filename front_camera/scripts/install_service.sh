#!/bin/bash
# ============================================================
# Install USB Camera Enhancement as systemd user service
# ============================================================
# Architecture (v2, C integration):
#   camera-router (C, single process):
#     - resident: videotestsrc(black) → GL chain → input-selector → v4l2sink → video99
#       (video99 always has a writer → format always valid)
#     - dynamic:   v4l2src→jpegdec→GL→gldownload added on reader open,
#                  removed on reader close (releases /dev/video14)
#   v4l2loopback: exclusive_caps=0 (Device declares CAPTURE+OUTPUT so
#     wireplumber creates a Video/Source node; D-1 v4 kernel patch makes
#     ENUM_FMT return only the writer's NV12 format)
#
# Usage: ./install_service.sh [--dry-run]
# Then:  systemctl --user start camera-enhancement
# Status: systemctl --user status camera-enhancement
# Stop:   systemctl --user stop camera-enhancement
# Logs:   journalctl -u camera-enhancement --user -f
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" )" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVICE_NAME="camera-enhancement.service"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"

DRY_RUN=false
[[ "${1-}" == "--dry-run" ]] && DRY_RUN=true

run_cmd() {
    if $DRY_RUN; then echo "[DRY-RUN] $*"; return 0; fi
    "$@"
}

echo "=== USB Camera Enhancement - Service Installer (v2 C router) ==="
if $DRY_RUN; then echo "(Dry run mode — no changes will be made)" ; fi
echo ""

# ---- Ensure v4l2loopback is available at boot ----
# 正确架构（实测验证）:
#  - /etc/modprobe.d/usb-camera-enhancement.conf: 模块 options
#    (modules-load.d 里的 options 行会被 systemd 忽略 — 这是"重启后
#    模块加载了但 video99 缺失/参数无效"的根因)
#  - /etc/modules-load.d/usb-camera-enhancement.conf: 仅模块名
MODPROBE_FILE="/etc/modprobe.d/usb-camera-enhancement.conf"
LOADER_FILE="/etc/modules-load.d/usb-camera-enhancement.conf"

# modprobe.d: options 参数（校验内容, 缺失/为空则重写）
if [ -f "$MODPROBE_FILE" ] && grep -q 'exclusive_caps=0' "$MODPROBE_FILE"; then
    echo "[OK] $MODPROBE_FILE already configured (exclusive_caps=0)"
else
    echo "[WARN] $MODPROBE_FILE missing/wrong — rewriting..."
    # 用临时文件 + sudo cp (避免 heredoc 直写权限问题)
    TMP_CONF=$(mktemp)
    cat > "$TMP_CONF" << 'MODPROBE_EOF'
# USB Camera Enhancement - v4l2loopback module options
# exclusive_caps=0: device declares CAPTURE+OUTPUT so wireplumber creates
#   a Video/Source node for video99 (exclusive_caps=1 with an active writer
#   only shows OUTPUT -> system camera doesn't enumerate the enhanced cam).
#   The D-1 v4 kernel patch makes ENUM_FMT return only the writer's NV12
#   format, so spa-v4l2/PipeWire negotiate NV12 (not the RGB table) ->
#   no EINVAL (-22) on link.
# max_buffers=16: buffer pool 2→16 fixes writer backpressure freeze when
#   PipeWire consumes slowly.
options v4l2loopback exclusive_caps=0 max_width=3840 max_height=2160 max_buffers=16 card_label=EnhancedCamera video_nr=99
MODPROBE_EOF
    run_cmd sudo cp "$TMP_CONF" "$MODPROBE_FILE"
    rm -f "$TMP_CONF"
fi

# modules-load.d: 仅模块名（options 行在此被 systemd 忽略, 勿写）
if [ -f "$LOADER_FILE" ] && grep -q '^v4l2loopback$' "$LOADER_FILE"; then
    echo "[OK] $LOADER_FILE already configured"
else
    echo "[WARN] $LOADER_FILE missing or empty — rewriting..."
    TMP_LOAD=$(mktemp)
    cat > "$TMP_LOAD" << 'MODULES_EOF'
# USB Camera Enhancement - load loopback module at boot
# (module options live in /etc/modprobe.d/usb-camera-enhancement.conf)
v4l2loopback
MODULES_EOF
    run_cmd sudo cp "$TMP_LOAD" "$LOADER_FILE"
    rm -f "$TMP_LOAD"
fi

# ---- Load module now if not present ----
if lsmod | grep -q v4l2loopback; then
    echo "[OK] v4l2loopback kernel module is loaded"
else
    run_cmd sudo modprobe v4l2loopback exclusive_caps=0 max_width=3840 max_height=2160 card_label=EnhancedCamera video_nr=99 2>/dev/null || {
        echo "WARN: Could not load v4l2loopback now; it will load at next reboot via modules-load.d."
    }
fi

# ---- Find loopback device ----
VIDEO_DEVICE="/dev/video99"
if [ ! -e "$VIDEO_DEVICE" ]; then
    # Try to find EnhancedCamera by label from v4l2-ctl
    LOOPBACK_DEV=$(v4l2-ctl --list-devices 2>/dev/null | grep -A2 "EnhancedCamera" | grep '/dev/video' | head -1 || true)
    if [ -n "$LOOPBACK_DEV" ]; then
        VIDEO_DEVICE="$LOOPBACK_DEV"
    else
        echo "WARN: Loopback device not found. It may be available after reboot when v4l2loopback loads."
        VIDEO_DEVICE="/dev/video99"  # Use default from module parameter
    fi
fi

echo "[OK] Loopback device: $VIDEO_DEVICE"

# ---- Create systemd user service ----
mkdir -p "$SYSTEMD_USER_DIR"

cat > "$SYSTEMD_USER_DIR/$SERVICE_NAME" << EOF
[Unit]
Description=EnhancedCamera Router - integrated on-demand GPU enhancement (single C process, videotestsrc resident + dynamic enhance chain)
Documentation=https://github.com/luoshirong-gmail/usb-camera-enhancement
# 时序关键: 必须在图形会话完全就绪后启动!
#  - camera-router 需要 Wayland 显示服务器才能初始化 GL 上下文
#  - 之前 WantedBy=default.target 在登录早期启动 → 无显示 → PLAYING failed
#    → Restart=on-failure 无限重启循环 → 黑屏无法进桌面
#  - graphical-session.target 在 Wayland 合成器就绪后激活 → GL 可用
#    (合并自 autostart 方案: 原方案靠 GNOME autostart 延迟登录后启动;
#     现统一用 graphical-session.target 时序, 更规范且单一启动源)
After=graphical-session.target pipewire.service wireplumber.service
PartOf=graphical-session.target
Wants=pipewire.service

[Service]
Type=simple
ExecStart=$PROJECT_DIR/pipeline/camera-router
# writer 就绪后刷新 wireplumber 枚举 (登录时枚举过"无 writer"的 video99,
# 节点缓存病态 → 应用协商失败; 重启重新枚举 → Node 格式正确)
# (合并自 autostart 方案: 原方案脚本里的 wireplumber 修复逻辑)
ExecStartPost=$PROJECT_DIR/scripts/camera-enhancement-wireplumber-refresh.sh
Restart=on-failure
RestartSec=5
# GL context from graphical session (inherit user session env).
# IMPORTANT: systemd user services started by default.target do NOT inherit
# WAYLAND_DISPLAY/DISPLAY (session manager sets them after login) — without
# these the pipeline refuses to start: "No display server detected".
Environment=XDG_RUNTIME_DIR=/run/user/$(id -u)
Environment=WAYLAND_DISPLAY=wayland-0
Environment=DISPLAY=:0

[Install]
WantedBy=graphical-session.target
EOF

echo "[OK] Service file: $SYSTEMD_USER_DIR/$SERVICE_NAME"

# ---- Enable and reload systemd ----
if ! $DRY_RUN; then
    systemctl --user daemon-reload
    systemctl --user enable "$SERVICE_NAME" 2>/dev/null || true  # may already be enabled
fi

# ---- Verify installation (catches the "empty conf file" failure mode) ----
if ! $DRY_RUN; then
    echo ""
    echo "=== Verification ==="
    if lsmod | grep -q v4l2loopback; then
        echo "[OK] v4l2loopback module loaded"
    else
        echo "[WARN] v4l2loopback NOT loaded — run: sudo modprobe v4l2loopback exclusive_caps=0 max_width=3840 max_height=2160 card_label=EnhancedCamera video_nr=99"
    fi
    if [ -e "$VIDEO_DEVICE" ]; then
        echo "[OK] Loopback device $VIDEO_DEVICE exists"
    else
        echo "[WARN] $VIDEO_DEVICE missing — will appear after reboot if modules-load.d is correct"
    fi
    if grep -q '^v4l2loopback$' "$LOADER_FILE" 2>/dev/null && grep -q 'exclusive_caps=0' "$MODPROBE_FILE" 2>/dev/null; then
        echo "[OK] boot persistence valid (modules-load.d + modprobe.d options)"
    else
        echo "[FAIL] boot persistence NOT configured — modules-load.d and/or modprobe.d missing/empty"
    fi
    echo "[OK] Service enabled: $(systemctl --user is-enabled "$SERVICE_NAME" 2>/dev/null || echo 'no')"
    echo ""
    echo "If PipeWire doesn't show EnhancedCamera, run: systemctl --user restart wireplumber"
fi

echo ""
echo "=== Installation complete ==="
echo ""
echo "Commands:"
echo "  Start:   systemctl --user start camera-enhancement"
echo "  Status:  systemctl --user status camera-enhancement"
echo "  Stop:    systemctl --user stop camera-enhancement"
echo "  Logs:    journalctl --user -u camera-enhancement -f"
echo ""
echo "In your camera app, select 'EnhancedCamera' as the device."
