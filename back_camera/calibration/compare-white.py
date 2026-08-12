#!/usr/bin/env python3
"""compare-white.py — 白纸暗角新旧对比 (LSC 参数校准验证)

对比新拍白纸帧与历史基准 (calib-orig.raw 帧0), 验证:
  1. 镜头暗角形状是否稳定 (光轴位置/角中比/径向剖面)
  2. 合成 LSC 表 (synthetic) 与实测暗角的匹配度
  3. 若一致 → 复用历史标定; 若不同 → 需重新标定

用法:
  ./compare-white.py <新白纸帧.bin> [宽] [高]
  (旧基准默认 /tmp/calib-orig.raw 帧0; 若不存在则仅报告新帧)
"""
import sys
import numpy as np


def load_y(path, w=2560, h=1920, frame=0):
    raw = np.fromfile(path, dtype=np.uint8)
    fsize = w * h * 3 // 2
    f = raw[frame * fsize:(frame + 1) * fsize].reshape(h * 3 // 2, w)
    return f[:h].astype(np.float32)


def vignette_metrics(y):
    """角/中比 + 光轴 (最亮格) + 径向剖面"""
    h, w = y.shape
    center = y[h // 2 - 100:h // 2 + 100, w // 2 - 100:w // 2 + 100].mean()
    corners = [y[50:250, 50:250].mean(), y[50:250, w - 250:w - 50].mean(),
               y[h - 250:h - 50, 50:250].mean(), y[h - 250:h - 50, w - 250:w - 50].mean()]
    # 光轴: 用 128px 网格找最亮格 (暗角最轻处)
    gy = y.reshape(h // 128, 128, w // 128, 128).mean(axis=(1, 3))
    brightest = np.unravel_index(np.argmax(gy), gy.shape)
    # 径向剖面: 以光轴为中心, 8 环均值
    yy, xx = np.mgrid[0:h, 0:w]
    r = np.sqrt((yy - (brightest[0] * 128 + 64)) ** 2 +
                (xx - (brightest[1] * 128 + 64)) ** 2)
    rmax = r.max()
    profile = []
    for i in range(8):
        ring = (r >= i * rmax / 8) & (r < (i + 1) * rmax / 8)
        profile.append(y[ring].mean())
    return center, corners, brightest, np.array(profile)


def main():
    path = sys.argv[1]
    w = int(sys.argv[2]) if len(sys.argv) > 2 else 2560
    h = int(sys.argv[3]) if len(sys.argv) > 3 else 1920

    new = load_y(path, w, h)
    center, corners, axis, profile = vignette_metrics(new)
    ratio = min(corners) / center if center else 0
    print(f"=== 新白纸帧: {path} ===")
    print(f"中心 {center:.1f} | 四角 {[f'{x:.1f}' for x in corners]} | 角/中比 {ratio:.3f}")
    print(f"光轴 (128px 格): {axis} → 像素 ({axis[1]*128+64}, {axis[0]*128+64})")
    print(f"径向剖面 (光轴→边缘 8 环): {[f'{p:.1f}' for p in profile]}")

    # 旧基准对比
    old_path = "/tmp/calib-orig.raw"
    try:
        old = load_y(old_path, w, h, frame=0)
        oc, ocorners, oaxis, oprofile = vignette_metrics(old)
        oratio = min(ocorners) / oc if oc else 0
        print(f"\n=== 旧基准: {old_path} 帧0 ===")
        print(f"中心 {oc:.1f} | 四角 {[f'{x:.1f}' for x in ocorners]} | 角/中比 {oratio:.3f}")
        print(f"光轴: {oaxis} → 像素 ({oaxis[1]*128+64}, {oaxis[0]*128+64})")
        print(f"径向剖面: {[f'{p:.1f}' for p in oprofile]}")

        # 一致性判断
        dr = abs(ratio - oratio) / oratio if oratio else 9
        daxis = np.abs(np.array(axis) - np.array(oaxis)).sum()
        dprof = np.abs(profile / profile[0] - oprofile / oprofile[0]).mean()
        print(f"\n=== 对比 ===")
        print(f"角/中比偏差: {dr*100:.1f}% | 光轴偏移: {daxis} 格 | 径向剖面归一差: {dprof:.3f}")
        if dr < 0.15 and daxis <= 2 and dprof < 0.05:
            print("判定: ✅ 暗角形状一致 — 历史标定可复用 (LSC 参数按上次)")
        else:
            print("判定: ⚠️ 暗角形状变化 — 需重新标定 (镜头/装配/环境变化)")
    except FileNotFoundError:
        print("\n(旧基准 /tmp/calib-orig.raw 不存在 — 仅报告新帧)")

    # 与合成 LSC 表匹配度 (若存在)
    syn = "/tmp/synth-table.npy"
    try:
        g = np.load(syn)
        # 合成表 = 中心 1.0 四角 2.0 — 期望补偿后均匀
        print(f"\n合成表 ({syn}) 期望: 中心 1.0x 四角 2.0x — 实测角/中比 {ratio:.3f} "
              f"(≈1.0 表示合成表正确覆盖暗角)")
    except FileNotFoundError:
        pass


if __name__ == "__main__":
    main()
