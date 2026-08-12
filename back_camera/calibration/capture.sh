#!/bin/bash
# capture.sh — libcamera 抓帧工具 (校准/分析用, 不碰 video16)
# 用法: ./capture.sh [帧数=6] [宽=2560] [高=1920] [输出目录=/tmp/calib-capture]
# 前置: 停止 router 服务释放 CAM6 (systemctl --user stop ov5670-virtual-camera.service)
set -e
N=${1:-6}; W=${2:-2560}; H=${3:-1920}; OUT=${4:-/tmp/calib-capture}
CAM='\_SB_.PCI0.I2C2.CAM6'
mkdir -p "$OUT"
echo "抓取 ${N} 帧 ${W}x${H} → $OUT (cam 直连, 需 CAM6 空闲)"
cam --camera="$CAM" --stream width=$W,height=$H --capture=$N \
    --file="$OUT/frame-#.bin" 2>&1 | tail -3
echo "完成: $(ls "$OUT"/frame-*.bin 2>/dev/null | wc -l) 帧"
