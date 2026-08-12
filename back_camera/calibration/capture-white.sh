#!/bin/bash
# capture-white.sh — 白纸校准抓帧 (cam 直连, 不碰 video16)
# 用法: ./capture-white.sh [输出=/tmp/white-new.raw] [帧数=6]
# 前置: 白纸/纯白物体对准镜头 (均匀照明)
set -e
OUT=${1:-/tmp/white-new.raw}
N=${2:-6}
CAM='\_SB_.PCI0.I2C2.CAM6'

echo "停 router (释放 CAM6)…"
systemctl --user stop ov5670-virtual-camera.service
sleep 2
echo "cam 直连抓取 ${N} 帧 2560x1920…"
cam --camera="$CAM" --stream width=2560,height=1920 --capture=$N \
    --file=/tmp/white-tmp-#.bin 2>&1 | tail -2
echo "恢复 router…"
systemctl --user start ov5670-virtual-camera.service
sleep 3
systemctl --user is-active ov5670-virtual-camera.service

# 合并为单文件 (帧0-5 连续 — 与 calib-orig.raw 同格式; cam 文件名:
# white-tmp-cam0-stream0-000000.bin 格式 — 用通配符按序号合并)
cat /tmp/white-tmp-cam0-stream0-*.bin > "$OUT" 2>/dev/null || true
rm -f /tmp/white-tmp-cam0-stream0-*.bin
echo "✅ 已存 $OUT ($(ls -la $OUT 2>/dev/null | awk '{print $5}') B)"
