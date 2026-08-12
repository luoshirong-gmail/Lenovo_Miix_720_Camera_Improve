#!/usr/bin/env python3
"""gen-lsc-from-raw.py — 从白纸原始帧实测反演 LSC 增益表 (硬件网格对齐版)

硬件语义 (intel-ipu3.h + 驱动 ipu3-css-params.c):
- 网格 43x36 格, block 64x64px → 覆盖 2752x2304
- x_start/y_start = 网格左上角相对 ROI (BDS 输出) 的负像素偏移 (s13,
  [-4096, 0], 默认 0) — 驱动 ops_calc 用 BDS 高度计算 set 布局
- ⚠️ 修正 (2026-08-11): ROI = BDS 输出 2592x1944 (SHD 在 BDS 后处理),
  非最终输出 2560x1920 — 网格中心对齐 BDS 中心:
  x_start = (2592-2752)/2 = -80, y_start = (1944-2304)/2 = -180
- 表 cell (r,c) 覆盖像素 x∈[c*64+x_start, c*64+x_start+64), y∈[r*64+y_start, ...)

用法: python3 gen-lsc-from-raw.py <raw.nv12> [输出yaml段文件]
"""
import sys
import numpy as np

W, H = 2560, 1920          # 最终输出 (GDC 裁切后)
BDS_W, BDS_H = 2592, 1944  # BDS 输出 = SHD 的 ROI (驱动语义)
GRID_W, GRID_H = 43, 36
BLOCK = 64
X_START = (BDS_W - GRID_W * BLOCK) // 2   # -80 (对齐 BDS 中心)
Y_START = (BDS_H - GRID_H * BLOCK) // 2   # -180
FRAME = W * H * 3 // 2
MAX_GAIN = 4.0          # 限幅: 角落增益上限
ANCHOR = 4096           # 1.0x 定点


def load_stable_frames(path):
    raw = np.fromfile(path, dtype=np.uint8)
    nf = len(raw) // FRAME
    ys = []
    for f in range(nf):
        y = raw[f * FRAME:f * FRAME + W * H].reshape(H, W).astype(np.float32)
        if y.mean() < 20 or y.max() < 40:
            continue
        ys.append(y)
    if not ys:
        raise SystemExit("无有效帧")
    return np.mean(ys, axis=0), nf


def grid_mean(y):
    """按硬件网格采样: cell (r,c) = 像素 [c*64+x_start, ...) × [r*64+y_start, ...) 与图像交集均值"""
    g = np.zeros((GRID_H, GRID_W), dtype=np.float32)
    for r in range(GRID_H):
        r0, r1 = max(0, Y_START + r * BLOCK), min(H, Y_START + (r + 1) * BLOCK)
        if r0 >= r1:
            continue
        for c in range(GRID_W):
            c0, c1 = max(0, X_START + c * BLOCK), min(W, X_START + (c + 1) * BLOCK)
            if c0 >= c1:
                continue
            g[r, c] = y[r0:r1, c0:c1].mean()
    return g


def main():
    path = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else "/tmp/lsc-measured.yaml"
    y, nf = load_stable_frames(path)
    g = grid_mean(y)
    # 光轴 = 图像最亮处 (128px 粗定位)
    gy = y.reshape(H // 128, 128, W // 128, 128).mean(axis=(1, 3))
    ax = np.unravel_index(np.argmax(gy), gy.shape)
    px, py = ax[1] * 128 + 64, ax[0] * 128 + 64
    # 光轴所在网格格
    gr = (py - Y_START) // BLOCK
    gc = (px - X_START) // BLOCK
    gr, gc = min(max(gr, 0), GRID_H - 1), min(max(gc, 0), GRID_W - 1)
    center_val = g[gr, gc]
    print(f"帧数 {nf}, 光轴 像素({px},{py}) → 网格({gr},{gc}), 中心亮度 {center_val:.1f}")
    print(f"网格四角亮度: {g[0,0]:.1f} {g[0,-1]:.1f} {g[-1,0]:.1f} {g[-1,-1]:.1f}")
    # 增益 = 光轴格亮度 / 格亮度 (光轴格 = 1.0x)
    gain = np.clip(center_val / np.maximum(g, 1.0), 1.0, MAX_GAIN)
    # 图像外格 (无传感器数据, g==0) 必须设 1.0 — 硬件插值会参考相邻格,
    # 若留 4.0 会把图像边缘抬亮
    gain[g == 0] = 1.0
    print(f"增益四角: {gain[0,0]:.3f} {gain[0,-1]:.3f} {gain[-1,0]:.3f} {gain[-1,-1]:.3f}")
    # 图像可见四角
    def cell_of(px, py):
        return min(max((py - Y_START) // BLOCK, 0), GRID_H - 1), min(max((px - X_START) // BLOCK, 0), GRID_W - 1)
    for name, (px, py) in [('左上', (0, 0)), ('右上', (W - 1, 0)), ('左下', (0, H - 1)), ('右下', (W - 1, H - 1))]:
        r, c = cell_of(px, py)
        print(f"  图像{name} px({px},{py}) → 格({r},{c}) 增益 {gain[r,c]:.3f}")
    # 检查网格外区域 (图像外格) 用 1.0
    fixed = np.clip(np.round(gain * ANCHOR), 1, 65535).astype(np.uint16)
    vals = ', '.join(str(v) for v in fixed.ravel())
    with open(out, 'w') as f:
        f.write("  - Lsc:\n")
        f.write(f"      gridWidth: {GRID_W}\n")
        f.write(f"      gridHeight: {GRID_H}\n")
        f.write(f"      blockWidthLog2: 6\n")
        f.write(f"      blockHeightLog2: 6\n")
        f.write(f"      xStart: {X_START}\n")
        f.write(f"      yStart: {Y_START}\n")
        f.write(f"      # 硬件网格对齐: 43x36x64px=2752x2304, xStart={X_START} yStart={Y_START} 网格中心=图像中心\n")
        f.write(f"      # 实测光轴 像素({px},{py}) 网格({gr},{gc}) = 1.0x; 源 {path}\n")
        f.write(f"      gains: [{vals}]\n")
    print(f"✅ 已写 {out} ({fixed.size} 值, 中心 {fixed[gr,gc]}, 四角 {fixed[0,0]},{fixed[0,-1]},{fixed[-1,0]},{fixed[-1,-1]})")


if __name__ == "__main__":
    main()
