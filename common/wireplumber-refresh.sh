#!/bin/bash
# wireplumber-refresh.sh — writer 就绪后修复 wireplumber 枚举 (统一参数化版)
# =========================================================================
# 合并自 (2026-08-08, 合并项目 P4):
#   - front: camera-enhancement-wireplumber-refresh.sh (video99)
#   - back:  ov5670-wireplumber-refresh.sh (video16)
# 取两版优点: ov5670 版的"仅病态时重启"逻辑 (正常时零副作用, 不打断音频)
# + 参数化设备号, 两服务 ExecStartPost 共用一份脚本。
#
# 背景: wireplumber 在系统启动时枚举 v4l2 设备, 若当时设备 writer 还没
#   上线, spa-v4l2 枚举到 CONTINUOUS/Range 异常帧率范围 → Snapshot 等
#   应用协商失败 (-22 无效参数 / fraction_range 断言)。
#   修复: 等 writer 就绪后检查 PipeWire 节点帧率是否 Range, 异常才重启
#   wireplumber 重扫 (writer 在线时枚举 → 固定帧率 → 应用正常)。
#
# 用法: wireplumber-refresh.sh <videoN>   (N 无 /dev/ 前缀, 如 99 或 16)
#   由 systemd user service ExecStartPost 调用:
#   ExecStartPost=/path/to/wireplumber-refresh.sh 99

set -u
DEV="video${1:?用法: wireplumber-refresh.sh <videoN> (如 99 或 16)}"
PW_CHECK=/tmp/wp-refresh-${DEV}.$$
trap 'rm -f $PW_CHECK' EXIT
export XDG_RUNTIME_DIR=/run/user/$(id -u)

# 1. 等待 writer 就绪 (state=capture), 最多 10s
for i in $(seq 1 20); do
    st=$(cat /sys/class/video4linux/${DEV}/state 2>/dev/null)
    if [ "$st" = "capture" ]; then
        break
    fi
    sleep 0.5
done
if [ "$st" != "capture" ]; then
    echo "${DEV} writer 未就绪 (state=${st:-无设备}), 跳过枚举修复"
    exit 0
fi

# 2. 找到 ${DEV} 的 PipeWire 节点
NODE_ID=$(timeout 5 pw-dump 2>/dev/null | python3 -c "
import json,sys
try:
    data=json.load(sys.stdin)
except Exception:
    sys.exit(1)
for obj in data:
    if obj.get('type')=='PipeWire:Interface:Node':
        props=obj.get('info',{}).get('props',{})
        if '${DEV}' in props.get('node.name',''):
            print(obj['id']); break
" 2>/dev/null)

if [ -z "$NODE_ID" ]; then
    echo "${DEV} PipeWire 节点未找到, 跳过"
    exit 0
fi

# 3. 检查节点 framerate 是否为异常 Range
#    正常: Choice None / Fraction 29/1; 异常: Choice Range
IS_RANGE=$(timeout 5 pw-cli enum-params "$NODE_ID" EnumFormat 2>/dev/null \
    | grep -A6 'framerate' | grep -c 'Choice: type Spa:Enum:Choice:Range')

if [ "$IS_RANGE" -gt 0 ]; then
    echo "${DEV} 节点帧率异常 (Range), 重启 wireplumber 重新枚举..."
    systemctl --user restart wireplumber.service
    echo "wireplumber 已重启, ${DEV} 节点应恢复正常"
else
    echo "${DEV} 节点帧率正常, 无需处理"
fi
exit 0
