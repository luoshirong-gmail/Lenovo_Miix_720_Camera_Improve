/* SPDX-License-Identifier: LGPL-2.1-or-later */
/*
 * Copyright (C) 2026, MIIX 720 camera project
 *
 * IPU3 Lens Shading Correction — 白纸实测校准 (见 lsc.h 说明)
 */

#include "lsc.h"

#include <algorithm>
#include <cmath>
#include <cctype>
#include <sstream>
#include <stdint.h>

#include <libcamera/base/log.h>

#include "ipu3_ipa_interface.h"

namespace libcamera {

LOG_DECLARE_CATEGORY(IPU3)

namespace ipa::ipu3::algorithms {

Lsc::Lsc()
{
}

int Lsc::init([[maybe_unused]] IPAContext &context, const YamlObject &tuningData)
{
	/* 网格参数 (缺省 73x56 + block 64x64, x_start/y_start 居中负偏移) */
	gridWidth_ = tuningData["gridWidth"].get<uint8_t>(gridWidth_);
	gridHeight_ = tuningData["gridHeight"].get<uint8_t>(gridHeight_);
	blockWidthLog2_ = tuningData["blockWidthLog2"].get<uint8_t>(blockWidthLog2_);
	blockHeightLog2_ = tuningData["blockHeightLog2"].get<uint8_t>(blockHeightLog2_);
	xStart_ = tuningData["xStart"].get<int16_t>(xStart_);
	yStart_ = tuningData["yStart"].get<int16_t>(yStart_);

	/* 增益表: 支持两种 yaml 格式 (2026-08-11 修复):
	 * 1) list: gains: [v0, v1, ...] — 标准 YAML, libcamera parser list
	 *    上限 2000, 1548 值 <=2000 ✓. 用 getList<uint16_t>() 读取.
	 * 2) 折叠标量字符串: gains: >- (逗号分隔) — 备用; 历史存在丢值
	 *    bug (yaml_parser 行级截断), 格式1优先.
	 * r/gr/gb/b 同增益 — 亮度暗角 (AIQB 0x26 第二段 = 单通道表). */
	unsigned int nCells = gridWidth_ * gridHeight_;
	/* 防御: rowsPerSlice = 146/width (硬件语义), gridHeight 必须能被整除,
	 * 否则 LUT 行无法完整装入 sets (标准: 驱动同公式计算后校验 <=0) */
	if (gridWidth_ == 0 ||
	    gridHeight_ % (IPU3_UAPI_SHD_MAX_CELLS_PER_SET / gridWidth_) != 0) {
		LOG(IPU3, Error) << "Lsc: 网格 " << (int)gridWidth_ << "x"
				 << (int)gridHeight_ << " 无法装入 sets (rowsPerSlice="
				 << (IPU3_UAPI_SHD_MAX_CELLS_PER_SET / gridWidth_) << ")";
		return -EINVAL;
	}
	if (tuningData.contains("gains")) {
		/* 格式1: list */
		auto listVals = tuningData["gains"].getList<uint16_t>();
		if (listVals) {
			gains_ = *listVals;
		} else {
			/* 格式2: 折叠标量字符串 (逗号分隔, 兼容旧格式) */
			std::string gainsStr = tuningData["gains"].get<std::string>("");
			if (gainsStr.empty()) {
				LOG(IPU3, Error) << "Lsc: gains 既非 list 也非字符串";
				return -EINVAL;
			}
			std::stringstream ss(gainsStr);
			std::string token;
			while (std::getline(ss, token, ',')) {
				token.erase(std::remove_if(token.begin(), token.end(),
							   [](unsigned char c) { return std::isspace(c); }),
					    token.end());
				if (!token.empty())
					gains_.push_back(std::stoul(token));
			}
		}
		if (gains_.size() != nCells) {
			LOG(IPU3, Error) << "Lsc: gains 数量错误 (期望 "
					 << nCells << ", 实际 " << gains_.size() << ")";
			return -EINVAL;
		}
	} else {
		LOG(IPU3, Error) << "Lsc: tuning 缺 gains";
		return -EINVAL;
	}

	LOG(IPU3, Info) << "Lsc: 网格 " << gridWidth_ << "x" << gridHeight_
			<< " block " << (1 << blockWidthLog2_) << "x"
			<< (1 << blockHeightLog2_) << " gains " << gains_.size();

	valid_ = true;
	return 0;
}

void Lsc::prepare([[maybe_unused]] IPAContext &context,
		  [[maybe_unused]] const uint32_t frame,
		  [[maybe_unused]] IPAFrameContext &frameContext,
		  ipu3_uapi_params *params)
{
	if (!valid_)
		return;

	/* SHD 网格配置:
	 * grid_height_per_slice = MAX_CELLS_PER_SET(146) / width (硬件语义,
	 * intel-ipu3.h 1142 行 + 驱动 ipu3-css-params.c 2125 行):
	 * 73 宽 → 2 行/set, 43 宽 → 3 行/set。
	 * ⚠️ LUT 填充必须用同一 grid_height_per_slice (原硬编码 2 行/set
	 * 在 43 宽时错位 → 伪影)。 */
	struct ipu3_uapi_shd_grid_config &grid = params->acc_param.shd.shd.grid;
	grid.width = gridWidth_;
	grid.height = gridHeight_;
	grid.block_width_log2 = blockWidthLog2_;
	grid.block_height_log2 = blockHeightLog2_;
	const unsigned int rowsPerSlice = IPU3_UAPI_SHD_MAX_CELLS_PER_SET / gridWidth_;
	grid.grid_height_per_slice = rowsPerSlice;
	grid.x_start = xStart_;
	grid.y_start = yStart_;

	/* SHD 使能 + 增益因子 (0 = 无 shift, 增益 1-5) */
	/* init_set_vrt_offst_ul: 驱动语义 = (-y_start >> block_height_log2) %
	 * grid_height_per_slice (ipu3-css-params.c 2132) — y_start 为负偏移,
	 * 必须取负再移位 (原实现直接用 yStart_ 在负值时符号错误) */
	params->acc_param.shd.shd.general.init_set_vrt_offst_ul =
		((-yStart_ >> blockHeightLog2_) % rowsPerSlice + rowsPerSlice) % rowsPerSlice;
	params->acc_param.shd.shd.general.shd_enable = 1;
	params->acc_param.shd.shd.general.gain_factor = 0;

	/* SHD 黑电平 = 0 (标准: 驱动 imgu_css_shd_defaults 全 0; 黑电平校正
	 * 由独立 BLC 算法负责 — blc.cpp 写 obgrid_param=64, 不重复干预) */
	params->acc_param.shd.shd.black_level.bl_r = 0;
	params->acc_param.shd.shd.black_level.bl_gr = 0;
	params->acc_param.shd.shd.black_level.bl_gb = 0;
	params->acc_param.shd.shd.black_level.bl_b = 0;

	/* LUT: sets = ceil(height / rowsPerSlice), 每 set rowsPerSlice 行 × width 格
	 * set = row / rowsPerSlice, cell = (row % rowsPerSlice) * width + col
	 * (⚠️ 2026-08-11 修复: 原硬编码 2 行/set — 43 宽时与硬件
	 * grid_height_per_slice=3 错位 → 伪影) */
	memset(&params->acc_param.shd.shd_lut, 0, sizeof(params->acc_param.shd.shd_lut));
	unsigned int set = 0, cell = 0;
	for (unsigned int row = 0; row < gridHeight_; row++) {
		set = row / rowsPerSlice;
		for (unsigned int col = 0; col < gridWidth_; col++) {
			cell = (row % rowsPerSlice) * gridWidth_ + col;
			uint16_t g = gains_[row * gridWidth_ + col];
			params->acc_param.shd.shd_lut.sets[set].r_and_gr[cell].r = g;
			params->acc_param.shd.shd_lut.sets[set].r_and_gr[cell].gr = g;
			params->acc_param.shd.shd_lut.sets[set].gb_and_b[cell].gb = g;
			params->acc_param.shd.shd_lut.sets[set].gb_and_b[cell].b = g;
		}
	}

	/* 设 use 标志 */
	params->use.acc_shd = 1;
}

REGISTER_IPA_ALGORITHM(Lsc, "Lsc")

} /* namespace ipa::ipu3::algorithms */

} /* namespace libcamera */
