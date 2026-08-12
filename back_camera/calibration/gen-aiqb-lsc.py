#!/usr/bin/env python3
"""gen-aiqb-lsc.py — 从 AIQB (Intel 官方 OV5670 tuning) 提取 LSC 段生成 yaml

2026-08-11 定位: major 0x26 块 @ 0xf510 (12384B = 43x36x4 u16, 4096=1.0 定点)
本脚本: 4 通道均值 → 单通道增益表 (43x36) → 生成 ov5670.yaml 的 Lsc 段
用法: ./gen-aiqb-lsc.py [--out lsc-aiqb.yaml] [--grid 43x36]
"""
import sys
import os
import numpy as np

AIQB = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tuning", "01ov5670.aiqb")
LSC_OFF, LSC_SIZE = 0xF510, 12384  # major 0x26 第一块

def main():
    out = "lsc-aiqb.yaml"
    args = sys.argv[1:]
    if args and args[0].startswith("--out"):
        out = args[1]

    data = open(AIQB, "rb").read()
    seg = data[LSC_OFF:LSC_OFF + LSC_SIZE]
    u16 = np.frombuffer(seg, dtype="<u2").astype(np.float32)
    print(f"AIQB LSC 段: {len(u16)} u16, 值域 {u16.min():.0f}-{u16.max():.0f}")

    # ⚠️ 2026-08-11 破解: 4 段分离 (每 1548), 第二段 = 2560x1920 模式 LSC
    # (光轴点精确 4096=1.0, 四角 2.26-2.55x — 暗角特征确认)
    gw, gh = 43, 36
    grid = u16[1548:3096].reshape(gh, gw)
    print(f"网格 {gw}x{gh} (第二段): 光轴={grid.min():.0f}@{np.unravel_index(grid.argmin(), grid.shape)} "
          f"四角={[f'{x:.0f}' for x in [grid[0,0], grid[0,-1], grid[-1,0], grid[-1,-1]]]}")

    # 增益基准: 4096=1.0 (实测乘法语义). AIQB 第二段值域 4096-21000 (1.0-5.1x)
    # ⚠️ 用 AIQB 原值 (poppy 官方配置 — 先试官方效果, 过亮再限幅)
    g = grid.copy()

    # 生成 yaml (折叠标量逗号分隔 — 单行: 多行折叠标量被 yaml_parser 丢值
    # 1548→1500 实测; 单行避免行级截断)
    vals = g.reshape(-1)
    gains = "        " + ", ".join(f"{v:.0f}" for v in vals)

    yaml = f"""# LSC from Intel AIQB (ChromeOS poppy, 同硬件 IPU3+OV5670) — 2026-08-11 试
# 来源: 01ov5670.aiqb major 0x26 @0xf510 (4 通道均值, 4096=1.0 实测乘法语义)
# 网格 43x36 block 64x64 (覆盖 2752x2304 > 2560x1920), 单通道亮度暗角
  - Lsc:
      gridWidth: 43
      gridHeight: 36
      blockWidthLog2: 6
      blockHeightLog2: 6
      xStart: 0
      yStart: 0
      gains: >-
{gains}
"""
    open(out, "w").write(yaml)
    print(f"输出: {out} ({len(vals)} 值)")

if __name__ == "__main__":
    main()
