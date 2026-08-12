/* SPDX-License-Identifier: LGPL-2.1-or-later */
/*
 * Copyright (C) 2026, MIIX 720 camera project
 *
 * IPU3 Lens Shading Correction (SHD/LSC) — 白纸实测校准
 *
 * 背景: libcamera 的 ipu3 不配置 ImgU 的 SHD 模块 (LSC 缺失 → 四周暗角
 * 明显, 角落/中心 ~0.47)。本算法从 tuning yaml 读网格增益
 * (白纸实测暗角反相生成, 见 calibration/gen-lsc-from-raw.py),
 * 在 prepare() 填 ImgU 的 shd_config + shd_lut。
 *
 * 增益格式: u16 定点, 4096 = 1.0 (u4.12); 网格 43x36, block 64x64
 * (log2 6/6) → 覆盖 2752x2304 ≥ BDS 输出 2592x1944。
 * x_start/y_start: 网格左上角相对 ROI (BDS 输出) 的负像素偏移 (s13,
 * intel-ipu3.h 1129 行) — 生成工具按 (BDS_W - 43*64)/2 计算。
 *
 * ⚠️ 标准对齐: rowsPerSlice = IPU3_UAPI_SHD_MAX_CELLS_PER_SET(146)/width
 * (驱动 ipu3-css-params.c 2125 行同公式); LUT 行主序 set=row/rowsPerSlice,
 * cell=(row%rowsPerSlice)*width+col; init_set_vrt_offst_ul 用 -y_start
 * (驱动 2132 行语义); SHD 黑电平 = 0 (BLC 由 blc.cpp 的 obgrid 负责)。
 */

#pragma once

#include "algorithm.h"

namespace libcamera {

namespace ipa::ipu3::algorithms {

class Lsc : public Algorithm
{
public:
	Lsc();
	~Lsc() = default;

	int init([[maybe_unused]] IPAContext &context,
		 const YamlObject &tuningData) override;
	void prepare(IPAContext &context, const uint32_t frame,
		     IPAFrameContext &frameContext,
		     ipu3_uapi_params *params) override;

private:
	bool valid_ = false;

	/* 网格配置 — 2026-08-11 定稿 (标准语义):
	 * 43x36 格 × block 64x64 (log2 6/6) = 覆盖 2752x2304 ≥ BDS 2592x1944;
	 * x_start/y_start = 网格左上角相对 ROI 的负像素偏移 (s13),
	 * 生成工具 (gen-lsc-from-raw.py) 按 (BDS - grid*block)/2 居中计算;
	 * 增益定点 4096 = 1.0 (u4.12) */
	uint8_t gridWidth_ = 43;
	uint8_t gridHeight_ = 36;
	uint8_t blockWidthLog2_ = 6;   /* 64px */
	uint8_t blockHeightLog2_ = 6;  /* 64px */
	int16_t xStart_ = 0;
	int16_t yStart_ = 0;

	/* 增益 LUT: 43x36 = 1548 格 (r/gr/gb/b 同增益) */
	std::vector<uint16_t> gains_;
};

} /* namespace ipa::ipu3::algorithms */

} /* namespace libcamera */
