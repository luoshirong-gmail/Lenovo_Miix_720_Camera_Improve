/* SPDX-License-Identifier: LGPL-2.1-or-later */
/*
 * Copyright (C) 2026, Camera Improve Project
 *
 * IPU3 CCM (Color Correction Matrix) algorithm
 *
 * 与 libcamera 标准 tuning 格式对齐 (rkisp1 Ccm 先例):
 *   - Ccm:
 *       ccms:
 *         - ct: 2500
 *           ccm: [[1.0, 0, 0], [0, 1.0, 0], [0, 0, 1.0]]
 *           offsets: [0, 0, 0]
 *         - ct: 6500
 *           ...
 * 缺省 (无 ccms 段) = 不启用 CCM — ImgU 保持驱动默认
 * imgu_css_ccm_defaults (libcamera 原行为, sensor 标定矩阵).
 * 定点: 8191 = 1.0 (s16); uapi 布局 m11,m12,m13,o_r,m21,...,o_b
 * (intel-ipu3.h 985 行); 色温按最近 ct 选择 (插值留待扩展).
 */

#pragma once

#include <array>
#include <vector>

#include <linux/intel-ipu3.h>

#include "algorithm.h"

namespace libcamera {

namespace ipa::ipu3::algorithms {

class Ccm : public Algorithm
{
public:
	Ccm() = default;
	~Ccm() = default;

	int init(IPAContext &context, const YamlObject &tuningData) override;
	void prepare(IPAContext &context, const uint32_t frame,
		     IPAFrameContext &frameContext,
		     ipu3_uapi_params *params) override;

private:
	struct CcmEntry {
		uint32_t ct;
		std::array<int16_t, 9> matrix;  /* 3x3 行主序 */
		std::array<int16_t, 3> offsets; /* o_r, o_g, o_b */
	};

	/** \brief 应用一个色温条目到 ccm_ (uapi 行主序+offsets 布局) */
	void applyEntry(const CcmEntry &e);

	std::vector<CcmEntry> entries_;
	bool valid_ = false;
	/* 当前应用的矩阵 (无 ccms 段时保持驱动默认, 不覆盖) */
	ipu3_uapi_ccm_mat_config ccm_ = {};
};

} /* namespace ipa::ipu3::algorithms */

} /* namespace libcamera */
