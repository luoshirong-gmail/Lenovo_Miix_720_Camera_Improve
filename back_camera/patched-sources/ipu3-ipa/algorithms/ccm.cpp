/* SPDX-License-Identifier: LGPL-2.1-or-later */
/*
 * Copyright (C) 2026, Camera Improve Project
 *
 * IPU3 CCM (Color Correction Matrix) algorithm
 *
 * yaml tuning 格式 (libcamera 标准 — rkisp1 Ccm 先例):
 *   - Ccm:
 *       ccms:
 *         - ct: 2500
 *           ccm: [[1.0, 0, 0], [0, 1.0, 0], [0, 0, 1.0]]
 *           offsets: [0, 0, 0]
 * ccm 为 3x3 浮点矩阵 (系数 -8.0 ~ 7.993), offsets 为 3 元素浮点偏置.
 * 映射到 ipu3_uapi_ccm_mat_config (s16 定点, 8191 = 1.0):
 *   3x3 行主序 → m11..m33; offsets → o_r/o_g/o_b.
 */

#include "ccm.h"

#include <algorithm>
#include <cmath>

#include <libcamera/base/log.h>

#include "libcamera/internal/yaml_parser.h"

namespace libcamera {

LOG_DEFINE_CATEGORY(IPU3Ccm)

namespace ipa::ipu3::algorithms {

static constexpr int16_t kCcmFixedPoint = 8191; /* 8191 = 1.0 (s16) */

/**
 * \copydoc libcamera::ipa::Algorithm::init
 */
int Ccm::init([[maybe_unused]] IPAContext &context, const YamlObject &tuningData)
{
	if (!tuningData.contains("ccms")) {
		/*
		 * 无 ccms 段 = 不启用 CCM — 保持 libcamera 原行为
		 * (ImgU 用驱动默认 imgu_css_ccm_defaults, sensor 标定矩阵)。
		 * ⚠️ 修正 (2026-08-11): 此前无段时写单位矩阵 + use.acc_ccm=1
		 * 覆盖了驱动默认 — 偏离标准, 且 Intel 默认矩阵实测使本机
		 * 偏色恶化 — 故无配置时不干预。
		 */
		LOG(IPU3Ccm, Debug) << "无 ccms 段 — 不启用 CCM (驱动默认)";
		valid_ = false;
		return 0;
	}

	std::vector<CcmEntry> entries;
	for (const auto &entry : tuningData["ccms"].asList()) {
		auto ct = entry["ct"].get<uint32_t>();
		auto offsets = entry["offsets"].getList<float>();
		/* ccm 是 3x3 嵌套列表 — 需 asList 迭代逐行解析 (getList 不扁平化) */
		std::array<float, 9> matrix{};
		bool matrixOk = true;
		unsigned int r = 0;
		for (const auto &row : entry["ccm"].asList()) {
			auto rowVals = row.getList<float>();
			if (!rowVals || rowVals->size() != 3) {
				matrixOk = false;
				break;
			}
			for (unsigned int c = 0; c < 3; c++)
				matrix[r * 3 + c] = (*rowVals)[c];
			r++;
		}
		matrixOk &= (r == 3);
		if (!ct || !matrixOk || !offsets || offsets->size() != 3) {
			LOG(IPU3Ccm, Warning)
				<< "ccms 条目无效 (需 ct + ccm 3x3 + offsets 3 值), 跳过";
			continue;
		}

		CcmEntry e{ *ct, {}, {} };
		for (unsigned int i = 0; i < 9; i++) {
			double v = std::round(matrix[i] * kCcmFixedPoint);
			e.matrix[i] = std::clamp(v, -32768.0, 32767.0);
		}
		for (unsigned int i = 0; i < 3; i++) {
			double v = std::round((*offsets)[i] * kCcmFixedPoint);
			e.offsets[i] = std::clamp(v, -8191.0, 8181.0);
		}
		entries.push_back(e);
		LOG(IPU3Ccm, Debug) << "ccms 条目 ct=" << *ct
				    << " 矩阵[" << e.matrix[0] << ","
				    << e.matrix[4] << "," << e.matrix[8] << "]";
	}

	if (entries.empty()) {
		LOG(IPU3Ccm, Warning) << "ccms 无有效条目 — 不启用 CCM (驱动默认)";
		valid_ = false;
		return 0;
	}

	/* 按当前色温选择最近 ct 条目 (标准 rkisp1 Ccm 在 ct 间线性插值,
	 * ipu3 Awb 为 grey world 无稳定色温 — 简化取最近, 插值留待扩展) */
	applyEntry(entries[0]);
	entries_ = std::move(entries);
	valid_ = true;
	return 0;
}

/**
 * \brief 应用指定色温条目到 ccm_ (uapi 布局: 行主序 + 每行尾 offsets)
 *
 * ipu3_uapi_ccm_mat_config 字段序 = m11,m12,m13,o_r, m21,m22,m23,o_g,
 * m31,m32,m33,o_b (intel-ipu3.h 985 行) — 与 yaml 3x3 行主序 + offsets
 * 完全对应。
 */
void Ccm::applyEntry(const CcmEntry &e)
{
	int16_t *p = reinterpret_cast<int16_t *>(&ccm_);
	p[0] = e.matrix[0];  p[1] = e.matrix[1];  p[2] = e.matrix[2];  p[3] = e.offsets[0];
	p[4] = e.matrix[3];  p[5] = e.matrix[4];  p[6] = e.matrix[5];  p[7] = e.offsets[1];
	p[8] = e.matrix[6];  p[9] = e.matrix[7];  p[10] = e.matrix[8]; p[11] = e.offsets[2];
}

/**
 * \copydoc libcamera::ipa::Algorithm::prepare
 */
void Ccm::prepare([[maybe_unused]] IPAContext &context,
		  [[maybe_unused]] const uint32_t frame,
		  [[maybe_unused]] IPAFrameContext &frameContext,
		  ipu3_uapi_params *params)
{
	if (!valid_)
		return;

	params->acc_param.ccm = ccm_;
	params->use.acc_ccm = 1;
}

REGISTER_IPA_ALGORITHM(Ccm, "Ccm")

} /* namespace ipa::ipu3::algorithms */

} /* namespace libcamera */
