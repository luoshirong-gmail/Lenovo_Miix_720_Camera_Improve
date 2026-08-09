#!/usr/bin/env python3
"""v1 vs v2 图像对比分析

用法: python3 compare-v1v2.py <目录> [图片名1 图片名2]
默认: 当前目录下的 ipu3-ov5670-output.jpg 与 ipu3-ov5670-output-v2.jpg
"""
import os
import sys
from PIL import Image
import numpy as np

directory = sys.argv[1] if len(sys.argv) > 1 else "."
names = sys.argv[2:4] or ['ipu3-ov5670-output.jpg', 'ipu3-ov5670-output-v2.jpg']

for name in names:
    a = np.asarray(Image.open(os.path.join(directory, name)).convert('RGB'), dtype=np.float32)
    Y = 0.299 * a[:, :, 0] + 0.587 * a[:, :, 1] + 0.114 * a[:, :, 2]
    lap = np.abs(4 * Y[1:-1, 1:-1] - Y[:-2, 1:-1] - Y[2:, 1:-1] - Y[1:-1, :-2] - Y[1:-1, 2:])
    h, w = Y.shape
    center = lap[h//4:3*h//4, w//4:3*w//4].mean()
    edge = np.concatenate([lap[:h//8].ravel(), lap[7*h//8:].ravel(),
                           lap[:, :w//8].ravel(), lap[:, 7*w//8:].ravel()]).mean()
    sat = a.max(axis=2) - a.min(axis=2)
    print(f'{name}:')
    print(f'  亮度={Y.mean():.1f} 暗{ (Y<64).mean()*100:.0f}% 中{((Y>=64)&(Y<=192)).mean()*100:.0f}% 亮{(Y>192).mean()*100:.0f}%')
    print(f'  拉普拉斯 均值={lap.mean():.2f} 中心={center:.2f} 边缘={edge:.2f} 边/中={edge/center:.2f}')
    print(f'  RGB={a[:,:,0].mean():.0f}/{a[:,:,1].mean():.0f}/{a[:,:,2].mean():.0f} 偏红(R-G)={a[:,:,0].mean()-a[:,:,1].mean():.0f} 饱和度={sat.mean():.1f}')
    print()
