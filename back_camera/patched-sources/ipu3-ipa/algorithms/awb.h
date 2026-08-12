/* SPDX-License-Identifier: LGPL-2.1-or-later */
/*
 * Copyright (C) 2021, Ideas On Board
 *
 * IPU3 AWB control algorithm
 */

#pragma once

#include <vector>

#include <linux/intel-ipu3.h>

#include <libcamera/geometry.h>

#include "libcamera/internal/vector.h"

#include "algorithm.h"

namespace libcamera {

namespace ipa::ipu3::algorithms {

/* Region size for the statistics generation algorithm */
static constexpr uint32_t kAwbStatsSizeX = 16;
static constexpr uint32_t kAwbStatsSizeY = 12;

struct Accumulator {
	unsigned int counted;
	struct {
		uint64_t red;
		uint64_t green;
		uint64_t blue;
	} sum;
};

class Awb : public Algorithm
{
public:
	Awb();
	~Awb();

	int init(IPAContext &context, const YamlObject &tuningData) override;
	int configure(IPAContext &context, const IPAConfigInfo &configInfo) override;
	void prepare(IPAContext &context, const uint32_t frame,
		     IPAFrameContext &frameContext,
		     ipu3_uapi_params *params) override;
	void process(IPAContext &context, const uint32_t frame,
		     IPAFrameContext &frameContext,
		     const ipu3_uapi_stats_3a *stats,
		     ControlList &metadata) override;

private:
	struct AwbStatus {
		double temperatureK;
		double redGain;
		double greenGain;
		double blueGain;
	};

private:
	void calculateWBGains(const ipu3_uapi_stats_3a *stats);
	void generateZones();
	void generateAwbStats(const ipu3_uapi_stats_3a *stats);
	void clearAwbStats();
	void awbGreyWorld();
	static constexpr uint16_t threshold(float value);
	static constexpr uint16_t gainValue(double gain);

	std::vector<RGB<double>> zones_;
	Accumulator awbStats_[kAwbStatsSizeX * kAwbStatsSizeY];
	AwbStatus asyncResults_;

	uint32_t stride_;
	uint32_t cellsPerZoneX_;
	uint32_t cellsPerZoneY_;
	uint32_t cellsPerZoneThreshold_;

	/*
	 * Grey World 统计偏差补偿系数 (tuning yaml 配置, 默认 1.0=无补偿):
	 * 非线性补偿仅作用于 gain>1 的部分: gain' = 1 + (gain-1)*k
	 * (gain<1 保持 — BNR wb_gains 是 u16 无法表达降增益, 白纸降 R 走 CCM)
	 */
	double redCompensation_ = 1.0;
	double blueCompensation_ = 1.0;

	/*
	 * BNR 静态配置 (tuning yaml "bnr.lut" 32 值可配, 缺省
	 * imguCssBnrDefaults = 原 libcamera 行为). 用途: 降噪强度
	 * (横纹/暗部行噪声的 ImgU 硬件通道). 其余字段 (wb_gains 动态、
	 * opt_center 等) 保持默认, 明天按横纹实验需要再扩.
	 */
	ipu3_uapi_bnr_static_config bnr_ = {};
};

} /* namespace ipa::ipu3::algorithms */

} /* namespace libcamera*/
