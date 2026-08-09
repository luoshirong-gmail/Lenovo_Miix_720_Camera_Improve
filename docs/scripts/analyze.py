#!/usr/bin/env python3
"""分析 IPU3 输出图像的客观画质指标

用法: python3 analyze.py <图片路径>
"""
import sys
from PIL import Image
import numpy as np

if len(sys.argv) < 2:
    print(f"用法: {sys.argv[0]} <图片路径>", file=sys.stderr)
    sys.exit(1)

img = Image.open(sys.argv[1])
print(f'尺寸: {img.size}, 模式: {img.mode}')
a = np.asarray(img.convert('RGB'), dtype=np.float32)
Y = 0.299 * a[:, :, 0] + 0.587 * a[:, :, 1] + 0.114 * a[:, :, 2]

# 曝光
print(f'亮度均值: {Y.mean():.1f} (0-255), 标准差: {Y.std():.1f}')
print('直方图: 暗(<64): {:.1f}% 中(64-192): {:.1f}% 亮(>192): {:.1f}%'.format(
    (Y < 64).mean() * 100, ((Y >= 64) & (Y <= 192)).mean() * 100, (Y > 192).mean() * 100))

# 清晰度 (拉普拉斯)
lap = np.abs(4 * Y[1:-1, 1:-1] - Y[:-2, 1:-1] - Y[2:, 1:-1] - Y[1:-1, :-2] - Y[1:-1, 2:])
print(f'拉普拉斯均值(边缘强度): {lap.mean():.2f}  方差: {lap.var():.1f}')
print('  经验参考: <10 很模糊, 10-30 中等, >30 清晰, >100 非常锐利')
print(f'拉普拉斯 95 分位: {np.percentile(lap, 95):.1f}')

# 色彩
print('RGB 均值: R={:.1f} G={:.1f} B={:.1f}'.format(a[:, :, 0].mean(), a[:, :, 1].mean(), a[:, :, 2].mean()))
sat = a.max(axis=2) - a.min(axis=2)
print(f'饱和度均值: {sat.mean():.1f} (0-255, <10 灰白, 30+ 鲜艳)')

# 中心 vs 边缘清晰度 (暗角/边缘模糊检测)
h, w = Y.shape
center = lap[h//4:3*h//4, w//4:3*w//4].mean()
edge = np.concatenate([lap[:h//8].ravel(), lap[7*h//8:].ravel(),
                       lap[:, :w//8].ravel(), lap[:, 7*w//8:].ravel()]).mean()
print(f'中心清晰度: {center:.2f}  边缘清晰度: {edge:.2f}  边缘/中心: {edge/center:.2f} (>0.7 正常, <0.5 边缘明显模糊)')
