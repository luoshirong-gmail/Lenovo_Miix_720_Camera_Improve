#!/bin/bash
# ov5670-af-selfheal.sh — 开机自愈: video16 对焦控件缺失时重建设备
# 背景 (2026-08-09 第三次复发): 重启后 ensure-device add video16 的
# 控件注册偶发不生效 (af_trigger/focus_auto/focus_absolute 缺失, 0/3)。
# 手动"协同重载 (rmmod+modprobe)"可恢复, 但需 root 且影响前摄。
# 此脚本: 检测控件缺失 → 停后摄服务 → delete+add video16 (重新注册
# 控件, 普通用户权限即可, 不影响 video99/前摄) → 启后摄服务。
# 幂等: 控件正常时无操作。

LOG=/tmp/ov5670-selfheal.log
DEV=/dev/video16
NAME="OV5670 Back Camera"

log() { echo "$(date '+%H:%M:%S') $1" >> "$LOG"; }

[ -e "$DEV" ] || { log "video16 不存在, 跳过"; exit 0; }

CTRLS=$(v4l2-ctl -d "$DEV" --list-ctrls 2>/dev/null)
if echo "$CTRLS" | grep -q 'af_trigger'; then
    log "对焦控件正常 (af_trigger 在位), 无需处理"
    exit 0
fi

log "对焦控件缺失 (0/3), 重建 video16..."
systemctl --user stop ov5670-virtual-camera.service
sleep 1
v4l2loopback-ctl delete 16 >> "$LOG" 2>&1 && log "delete 16 OK" || log "delete 16 失败"
sleep 1
v4l2loopback-ctl add -n "$NAME" -w 3840 -h 2160 -b 16 -x 0 16 >> "$LOG" 2>&1
sleep 1
systemctl --user start ov5670-virtual-camera.service
sleep 3
CTRLS2=$(v4l2-ctl -d "$DEV" --list-ctrls 2>/dev/null)
if echo "$CTRLS2" | grep -q 'af_trigger'; then
    log "重建成功: 对焦控件恢复 (3/3)"
else
    log "重建失败: 控件仍缺失"
fi
exit 0
