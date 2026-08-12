#!/usr/bin/env python3
"""analyze.py — NV12 帧分析工具 (校准/画质验证用)

用法:
  ./analyze.py <frame.bin> [宽] [高]        # 分区 Y/U/V + 亮度带偏色
  ./analyze.py rows <frame.bin> [宽] [高]   # 行剖面分析 (横纹 FFT/自相关)
  ./analyze.py vignette <frame.bin> [宽] [高]  # 暗角统计 (中心/四角亮度比)

默认 2560x1920 NV12。输出 YUV 偏移 (128=中性): U+偏蓝/绿, V+偏红/绿。
"""
import sys
import numpy as np

def load(path, w=2560, h=1920):
    raw = np.fromfile(path, dtype=np.uint8)
    f = raw[: w * h * 3 // 2].reshape(h * 3 // 2, w)
    y = f[:h].astype(np.float32)
    uv = f[h:].reshape(h // 2, w)
    u = uv[:, 0::2].astype(np.float32)
    v = uv[:, 1::2].astype(np.float32)
    return y, u, v

def zones(path, w, h):
    y, u, v = load(path, w, h)
    print(f"{'区域':6s} | {'Y':>6s} | {'U偏移':>7s} | {'V偏移':>7s}")
    regions = {
        "中心": (y[h//2-200:h//2+200, w//2-200:w//2+200],
                 u[h//4-100:h//4+100, w//4-100:w//4+100],
                 v[h//4-100:h//4+100, w//4-100:w//4+100]),
        "左上": (y[50:350, 50:450], u[25:175, 25:225], v[25:175, 25:225]),
        "右上": (y[50:350, w-450:w-50], u[25:175, w//2-225:w//2-25], v[25:175, w//2-225:w//2-25]),
        "左下": (y[h-350:h-50, 50:450], u[h//2-175:h//2-25, 25:225], v[h//2-175:h//2-25, 25:225]),
        "右下": (y[h-350:h-50, w-450:w-50], u[h//2-175:h//2-25, w//2-225:w//2-25], v[h//2-175:h//2-25, w//2-225:w//2-25]),
    }
    for name, (yy, uu, vv) in regions.items():
        print(f"{name} | {yy.mean():6.1f} | {uu.mean()-128:+7.2f} | {vv.mean()-128:+7.2f}")
    print(f"\n全画面 | {y.mean():6.1f} | {u.mean()-128:+7.2f} | {v.mean()-128:+7.2f}")
    print("\n[亮度带偏色]")
    for lo, hi, nm in [(0, 50, "极暗"), (50, 90, "暗"), (90, 140, "中间"), (140, 256, "亮")]:
        m = (y >= lo) & (y < hi)
        mu = m[::2, ::2]
        if mu.sum() < 100:
            continue
        print(f"  {nm} (Y{lo}-{hi}) | U={u[mu].mean()-128:+.2f} V={v[mu].mean()-128:+.2f}")

def rows(path, w, h):
    from numpy.fft import rfft, rfftfreq
    y, _, _ = load(path, w, h)
    row_mean = y.mean(axis=1)
    x = np.arange(h)
    detrend = row_mean - np.polyval(np.polyfit(x, row_mean, 5), x)
    print(f"行剖面(去5次拟合): std={detrend.std():.3f} max|.|={np.abs(detrend).max():.3f}")
    d = np.diff(detrend)
    print(f"行间差分 std={d.std():.3f}")
    spec = np.abs(rfft(detrend))
    freqs = rfftfreq(h, 1)
    band = (freqs > 1 / 32) & (freqs <= 1 / 2)
    if band.any() and spec[band].any():
        pk = np.argmax(spec[band])
        print(f"行纹路主周期≈{1/freqs[band][pk]:.1f} 行 (幅度 {spec[band][pk]:.1f})")
    ac = np.correlate(detrend, detrend, 'full')[h-1:]
    ac /= ac[0]
    print(f"自相关 lag13-15: {ac[13]:.3f} {ac[14]:.3f} {ac[15]:.3f} (>0.3 提示准周期)")

def vignette(path, w, h):
    y, _, _ = load(path, w, h)
    center = y[h//2-100:h//2+100, w//2-100:w//2+100].mean()
    corners = [
        y[50:250, 50:250].mean(), y[50:250, w-250:w-50].mean(),
        y[h-250:h-50, 50:250].mean(), y[h-250:h-50, w-250:w-50].mean(),
    ]
    ratio = min(corners) / center if center > 0 else 0
    print(f"中心 {center:.1f} | 四角 {[f'{c:.1f}' for c in corners]} | 角/中比 {ratio:.3f}")
    print(f"(1.0=无暗角; 0.47 左右 = 重度暗角 — LSC 目标)")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    # 兼容: ./analyze.py <bin> [w] [h]  (省略 mode = zones)
    if sys.argv[1] in ("rows", "vignette", "zones"):
        mode, path = sys.argv[1], sys.argv[2]
        w = int(sys.argv[3]) if len(sys.argv) > 3 else 2560
        h = int(sys.argv[4]) if len(sys.argv) > 4 else 1920
    else:
        mode, path = "zones", sys.argv[1]
        w = int(sys.argv[2]) if len(sys.argv) > 2 else 2560
        h = int(sys.argv[3]) if len(sys.argv) > 3 else 1920
    if mode == "rows":
        rows(path, w, h)
    elif mode == "vignette":
        vignette(path, w, h)
    else:
        zones(path, w, h)
