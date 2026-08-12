# calibration — 校准工具链

抓帧 → 分析 → 生成 tuning 配置 的流水线工具。

## 工具

| 工具 | 用途 | 用法 |
|---|---|---|
| `capture.sh` | libcamera 直连抓帧 (不碰 video16) | `./capture.sh [帧数] [宽] [高] [输出目录]` — 前置: 停 router 释放 CAM6 |
| `analyze.py` | NV12 帧分析 | `./analyze.py <bin> [宽] [高]` (分区偏色) / `rows` (横纹) / `vignette` (暗角) |
| `gen-row-fpn.py` | **行 FPN 偏移表生成** (行噪声校准) | `./gen-row-fpn.py <帧...> [--out row_fpn.txt]` — 源: 暗帧(盖镜头)优先/纯色墙; 输出注入 `make_shader.py --fpn-file` |

## 典型流程

```bash
systemctl --user stop ov5670-virtual-camera.service   # 释放 CAM6
./capture.sh 6 2560 1920 /tmp/calib-x
./analyze.py /tmp/calib-x/frame-000000.bin            # 偏色/暗角
./analyze.py rows /tmp/calib-x/frame-000000.bin       # 横纹
systemctl --user start ov5670-virtual-camera.service  # 恢复
```

## 配置生成 (2026-08-11 计划)

- 白纸校准已放弃 (室内白纸偏色不准 — 用户决定)
- **现成配置优先**: 从 Intel AIQB (01ov5670.aiqb) 或同硬件 (IPU3+OV5670)
  机型提取 LSC/CCM/BNR/AWB 参数 → 转 ov5670.yaml (见 tuning/README.md 格式)
- 分析脚本输出可直接指导手工填 yaml 段

## 校准资产

- `../calibration-frames/` — 历史白纸帧 (orig-white-clean.png = 权威基准,
  供 AIQB 参数交叉验证用)
- `/tmp/calib-orig.raw` — ENHANCE=0 白纸原始帧 (帧0-5 稳定段)
