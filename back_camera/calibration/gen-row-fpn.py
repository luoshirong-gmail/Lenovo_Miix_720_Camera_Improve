#!/usr/bin/env python3
"""gen-row-fpn.py — 行 FPN 偏移表生成器 (校准工具链)

从任意均匀场景帧计算 sensor 固定行噪声 (FPN) 偏移表,
供 shader STAGE 7 逐行减偏移使用。

校准源 (无需白纸):
  1. 首选: 暗帧 (盖镜头 — 无场景纹理, 逐行均值 = 纯 FPN)
  2. 次选: 纯色墙面/均匀光照场景
  (行 FPN 是固定图案, 与拍摄内容无关, 多帧平均去随机分量即可)

用法:
  ./gen-row-fpn.py <帧1.bin> [帧2.bin ...] [--width 2560] [--height 1920]
                   [--out row_fpn.txt] [--smooth 5]

算法:
  1. 多帧平均 (去随机行噪声) → 每行 Y 均值
  2. 去大尺度趋势 (行方向 5 次多项式 — 暗角/光照纵向分量不是 FPN)
  3. 残差相对全局均值 = 行偏移表 (输出每行一个 float)

注意: 输出表方向与 shader v_texcoord.y 方向匹配 (若画面上下颠倒,
校准时交换 --flip 即可); 表行数必须等于帧高度。
FPN 幅度随模拟增益变化 (暗电流放大) — 若实测漂移明显, 需按增益缩放
(明天评估)。
"""
import sys
import numpy as np


def load_y(path, w, h):
    raw = np.fromfile(path, dtype=np.uint8)
    f = raw[: w * h * 3 // 2].reshape(h * 3 // 2, w)
    return f[:h].astype(np.float32)


def main():
    files, w, h, out, smooth = [], 2560, 1920, "row_fpn.txt", 5
    i = 1
    while i < len(sys.argv):
        a = sys.argv[i]
        if a.startswith("--width"):
            w = int(sys.argv[i + 1]); i += 2
        elif a.startswith("--height"):
            h = int(sys.argv[i + 1]); i += 2
        elif a.startswith("--out"):
            out = sys.argv[i + 1]; i += 2
        elif a.startswith("--smooth"):
            smooth = int(sys.argv[i + 1]); i += 2
        elif a.startswith("--flip"):
            i += 1  # 预留: 方向翻转
        else:
            files.append(a); i += 1

    if not files:
        print(__doc__)
        sys.exit(1)

    ys = np.array([load_y(f, w, h) for f in files])
    print(f"帧数: {len(ys)} ({w}x{h})")

    mean = ys.mean(axis=0)          # 多帧平均
    row_mean = mean.mean(axis=1)    # 每行均值
    x = np.arange(h)
    trend = np.polyval(np.polyfit(x, row_mean, 5), x)  # 大尺度趋势
    fpn = row_mean - trend          # 残差 = FPN 偏移
    fpn -= fpn.mean()               # 归零 (整体亮度不动)

    # 平滑 (FPN 表逐行应平滑 — 去帧间残余噪声)
    if smooth > 1:
        k = np.ones(smooth) / smooth
        fpn = np.convolve(fpn, k, mode="same")

    print(f"FPN 偏移: std={fpn.std():.3f} max|.|={np.abs(fpn).max():.3f}")
    with open(out, "w") as f:
        f.write("\n".join(f"{v:.4f}" for v in fpn))
    print(f"输出: {out} ({len(fpn)} 行) — 注入: make_shader.py --fpn-file={out}")


if __name__ == "__main__":
    main()
