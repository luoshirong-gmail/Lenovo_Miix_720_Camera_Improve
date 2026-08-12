# Windows 驱动调校数据挖掘 (2026-08-12)

来源: Windows 分区 `System32/`（Lenovo MIIX 720 出厂系统）

## 文件清单

| 文件 | 大小 | 内容 |
|---|---|---|
| `OV5670_CJAG514_SKY.cpf` | 163KB | **Intel AIQB 调校数据** — 头部字符串 "Lenovo_chicony_ov5670_WW29.1" (联想+群光模组, IQ Studio 2016) |
| `OV5670_CJAG514_SKY_pipeCfg.bin` | 307KB | ImgU 管线配置 (纯整数, 无 CCM/浮点) |
| `OV5670_REAR.aiqd` | 41KB | AIQ 数据 (2025 版) |
| `ov5670.sys` | 159KB | Windows sensor 驱动 |

## AIQB 格式逆向 (Intel 专有, 无公开文档)

- **文件头**: magic "AIQB" + u32 文件大小 + **u32 校验和** (全文件 u32 累加和 == 2×offset0x14, 已数学验证)
- **记录流** (从 0x18 起): 每条 = u32 大小 + u16 tag@0x6, 共 25 条
- **解析库**: Intel `libia_cmc_parser.so` (GitHub Intel-5xx-Camera/intel-camera-adaptation)
  - `ia_cmc_parser_init(info={data,size})` → parser 结构 (内部已解析全部 tag≤63 记录)
  - 反汇编确认调用协议: info 结构 {data@0, size@8}

## 记录语义 (25 条)

| tag | 大小 | 内容 |
|---|---|---|
| 1 | 176B | 名称/版本字符串 |
| 2 | 16B | sensor 分辨率 2592x1944 |
| 3 | 248B | AWB 颜色特性 (f32 对, 值域 0.9-4.0, 结构未完全明确) |
| 10 | 61KB | **LSC 表: 24 组 41x31 网格 u16 定点** (组16-23 为正常暗角响应) |
| 258 | 12.4KB | 6176 u16 = 43x36 网格位置映射表 (1544×2×2) |
| 513 | 22.5KB+3×20.6KB | AIQ LSC 描述 (u64 头+偏移表) |
| 259-263 | 小 | AGC/曝光增益映射 (含 4500K 色温点) |

## 导出成果

- `ov5670-lsc-41x31-gain.npy/.csv` — **LSC 增益表** (组17: 中心 1.0 → 四角 1.37, 最大 2.57 角落)
- `ov5670-lsc-41x31-raw.npy` — 原始响应表

## 关键结论

1. **CCM**: Windows 调校数据**无显式 3×3 CCM 矩阵** — Intel 相机栈用默认/单位 CCM
   → **验证了我们的单位矩阵方向** (消除驱动默认 B 1.97x 偏紫)
2. **LSC**: Windows 标定暗角 **角落:中心 = 1.37** (纯镜头, 标准照明)
   → GPU 链当前 VIGNETTE 参数 (1.1/0.85 = 1.29) 已接近, 微调 VIGNETTE→1.16 即对齐
   → 参考图暗角 2.57 是盖板背光不均叠加, 非纯镜头特性
3. **AWB**: rec 3/4 有色温特性表, 但 grey world 算法不直接使用 (参考价值)

## 工具

- `aiqb-dump.c` — AIQB 记录表遍历
- `aiqb-parse7.c` — 用 libia_cmc_parser.so 解析记录 (需库: /tmp/intel-aiq/usr/lib/libia_cmc_parser.so)
- `aiqb-semantics.py` — 记录语义分析
