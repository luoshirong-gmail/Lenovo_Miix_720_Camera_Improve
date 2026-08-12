# ov5670.yaml — tuning 格式说明

libcamera IPU3 tuning 文件 (`/usr/share/libcamera/ipa/ipu3/ov5670.yaml`,
运行实例由服务 `LIBCAMERA_IPU3_TUNING_FILE` 指向本目录文件)。
格式遵循 libcamera 官方 tuning 规范 (算法段 + yaml 1.1)。

## 文件来源 (调校资产, 全部公开渠道 Apache-2.0)

| 文件 | 内容 | 来源 |
|---|---|---|
| `ov5670.yaml` | **自制 libcamera tuning** (当前生效) | 本项目 (CC0-1.0) |
| `01ov5670.aiqb` | **Intel 官方 AIQ 3A 调校** (黑电平/增益/AWB/CCM/NR/LSC 全套, 2017 IQStudio, 滤波器 SKL_2015ww22a) — **同硬件 (IPU3+OV5670) 现成配置, 明天提取参数的来源** | ChromeOS `cros-camera-hal-configs-poppy` `tuning_files/` |
| `graph_settings_ov5670.xml` | Intel ImgU 管线配置 + sensor 模式 (Bayer=GRBG) | ChromeOS 同仓库 `gcss/` |
| `lsc-tuning.yaml` | LSC 实测生成 (4096=1.0, 帧0-5 稳定段) — 明天续试起点 | 本项目 |

## 算法段

### Agc
```yaml
- Agc:
    relativeLuminanceTarget: 0.35   # 曝光目标亮度 (0-1)
```

### Awb — Grey World 白平衡 (本机扩展段)
```yaml
- Awb:
    redCompensation: 1.15    # float, 缺省 1.0=无补偿
    blueCompensation: 1.10   # float, 缺省 1.0=无补偿
```
- 语义: Grey World 统计偏差非线性补偿, 仅作用于 gain>1:
  `gain' = 1 + (gain-1) × k` (gain<1 保持 — BNR wb_gains 为 u16 无法降增益)
- 硬件映射: `acc_param.bnr.wb_gains.{r,b}` (U3.13 定点, 经 gainValue)

### Awb → bnr (Bayer 降噪 — 本机扩展段)
```yaml
- Awb:
    bnr:
      lut: [17, 23, ..., 90]   # 32 个 u8, 缺省=imguCssBnrDefaults
```
- 语义: BNR 平方根查找表 (降噪强度), 32 值
- 硬件映射: `ipu3_uapi_bnr_static_config_lut_config.values[32]` (`IPU3_UAPI_BNR_LUT_SIZE`)

### Ccm — 色域校正 (libcamera 标准格式, rkisp1 Ccm 先例)
```yaml
- Ccm:
    ccms:
      - ct: 2500                 # 色温 K (当前取列表第一个条目应用)
        ccm:                     # 3x3 浮点矩阵, 系数 -8.0 ~ 7.993
          - [1.0, 0, 0]
          - [0, 1.0, 0]
          - [0, 0, 1.0]
        offsets: [0, 0, 0]       # 3 元素浮点偏置 (o_r, o_g, o_b)
```
- 硬件映射: `ipu3_uapi_ccm_mat_config` (s16 定点, **8191=1.0**):
  `ccm` 3x3 行主序 → `coeff_m11..m33`; `offsets` → `coeff_o_r/o_g/o_b`
- 缺省 (无 ccms) = 单位矩阵 (原 libcamera 行为)
- 用途: sensor 固定光谱偏色 (如白纸偏红需降 R — CCM s16 是唯一可降增益的硬件通道)

### Lsc — 镜头阴影校正 (SHD 硬件)
```yaml
- Lsc:
    gridWidth: 73         # u8 网格宽
    gridHeight: 56        # u8 网格高
    blockWidthLog2: 5     # u8 格宽 log2 (32px)
    blockHeightLog2: 6    # u8 格高 log2 (64px)
    xStart: 0             # s16 网格起始 X
    yStart: 0             # s16 网格起始 Y
    gains: >-             # 折叠标量逗号分隔 (gridWidth×gridHeight 值,
      4096, 4096, ...     #   规避 yaml 解析器 list 节点上限 2000)
```
- 硬件映射: `acc_param.shd.shd.grid` + `shd_lut` (每格 r/gr/gb/b 四通道 u16),
  `use.acc_shd=1`; 增益定点 **4096=1.0** (乘法语义, 2026-08-11 实测确认)
- ⚠️ LUT 布局/网格几何尚未最终确认 (明天续试 — 见 patched-sources 备注)

### BlackLevelCorrection
```yaml
- BlackLevelCorrection:   # 硬件默认; OV5670 BLC=64 实测正确 (方向1 关闭)
```

### ToneMapping
```yaml
- ToneMapping:            # 模块默认 (参数 yaml 化待评估)
```

## 验证机制 (2026-08-11 完成)

- tuning 路径: 服务 `LIBCAMERA_IPU3_TUNING_FILE` 指向本项目文件 (版本统一)
- 逻辑验证: Awb 补偿系数 / Ccm ccms 3x3 / BNR lut 均实测确认 yaml→acc_param 生效
- 调参流程: 改本文件 → `systemctl --user restart ov5670-virtual-camera.service`
  (无需重编译/sudo)
