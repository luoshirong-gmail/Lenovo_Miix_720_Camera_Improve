#!/bin/bash
# ov5670-ensure-device.sh — 固化: 确保 /dev/video98 存在 (开机自愈)
# ⚠️ 2026-08-07: video98 → video16 (腾讯会议枚举范围测试 — 腾讯会议只枚举
# 连续段 video0-15, video16 存在则会被枚举到, video98 超出段从未被看到)
# 开机时 video16 可能不存在 (v4l2loopback-ctl 动态创建的设备重启后消失)
# 此脚本在 service 启动前运行, 幂等: 已存在则跳过

DEV=/dev/video16
NAME="OV5670 Back Camera"

if [ -e "$DEV" ]; then
    echo "video16 已存在, 跳过创建"
    # ⚠️ 2026-08-12 21:00 (回归回退): 移除 keep_format=1 —
    # 它锁死重启后设备默认格式 (BGR4 640x480), ENUM_FMT 只报 BGR4
    # → router v4l2sink NV12 协商失败 → not-negotiated 崩溃循环。
    # keep_format 是为修 v4l2loopback.c:2189 读端 STREAMON EIO 加的,
    # 但副作用 > 收益; EIO 场景需重启后实测确认是否真出现。
    exit 0
fi

echo "创建 $DEV (动态 v4l2loopback 设备)"
v4l2loopback-ctl add -n "$NAME" -w 3840 -h 2160 -b 16 -x 0 16
RC=$?

if [ $RC -ne 0 ]; then
    echo "ERROR: v4l2loopback-ctl add failed (rc=$RC)"
    exit 1
fi

# 等待设备节点出现
for i in $(seq 1 20); do
    [ -e "$DEV" ] && break
    sleep 0.3
done

[ -e "$DEV" ] && echo "video16 创建成功" || { echo "ERROR: video16 未出现"; exit 1; }

# ⚠️ 2026-08-12 21:00 (回归回退): 新建设备同样不再设 keep_format=1 (同上方原因)
exit 0
