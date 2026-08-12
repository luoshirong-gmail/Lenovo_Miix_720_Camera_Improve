#!/bin/bash
# capture-uniform-ref.sh v2 — 单进程内预热+抓帧 (修复跨进程 AGC 重置问题)
# 教训: 每次 cam 进程启动 libcamera 重新初始化曝光 (DelayedControls 初始
#   值 + AGC 爬升) — 预热会话的收敛状态不传递到正式会话 (实测: 正式会话
#   第2帧全黑, 第1帧 63 vs 稳定 68)。
# 方案: 单进程 capture=8, 丢弃前 3 帧文件, 保留后 5 帧 (AGC 会话内收敛)
set -e
CAM='\_SB_.PCI0.I2C2.CAM6'
N=${1:-5}
TOTAL=$((N + 3))
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/calibration-frames"
mkdir -p "$DIR"

echo "停 router (释放 CAM6)…"
systemctl --user stop ov5670-virtual-camera.service
sleep 2

echo "单进程抓 ${TOTAL} 帧 (前 3 帧 AGC 爬升丢弃, 保留后 ${N} 帧)…"
cam --camera="$CAM" --stream width=2560,height=1920 --capture=$TOTAL \
    --file="$DIR/ref-#.bin" 2>&1 | tail -2

echo "恢复 router…"
systemctl --user start ov5670-virtual-camera.service
sleep 3
systemctl --user is-active ov5670-virtual-camera.service

# 丢弃前 3 帧 (AGC 爬升帧), 保留帧从 ref-01 起编号
DISCARD=3
i=1
for f in "$DIR"/ref-cam0-stream0-*.bin; do
    [ -e "$f" ] || continue
    if [ "$i" -le "$DISCARD" ]; then
        rm -f "$f"
    else
        mv "$f" "$DIR/ref-$(printf '%02d' $((i - DISCARD))).raw"
    fi
    i=$((i+1))
done

echo "=== 产出 ==="
ls -la "$DIR"/ref-*.raw 2>/dev/null | awk '{print $NF, $5"B"}'
echo "✅ 完成: $((i - DISCARD - 1)) 帧 (单进程内 AGC 收敛后拍摄)"
