/* SPDX-License-Identifier: LGPL-2.1-or-later */
/*
 * Copyright (C) 2021, Red Hat
 *
 * IPU3 Af algorithm
 *
 * ⚠️ 2026-08-08 (全新重做, 基于原版 0.7.0):
 *   - 三模式状态机: manual(0) / auto(1) / continuous(2)
 *   - settle 帧计数等待 (C1'/C4): 帧率 29fps 硬件节拍固定 → 帧数=时间,
 *     天然抗 CPU 负载 (负载只影响决策及时性, 不影响统计正确性)
 *   - 峰值邻域 settle (C1') + 回步确认 (C3) + 方差滑动平均 (C2)
 */

#pragma once

#include <linux/intel-ipu3.h>

#include <libcamera/base/utils.h>

#include <libcamera/geometry.h>

#include "algorithm.h"

namespace libcamera {

namespace ipa::ipu3::algorithms {

class Af : public Algorithm
{
	/* The format of y_table. From ipu3-ipa repo */
	typedef struct __attribute__((packed)) y_table_item {
		uint16_t y1_avg;
		uint16_t y2_avg;
	} y_table_item_t;

public:
	Af();
	~Af() = default;

	int configure(IPAContext &context, const IPAConfigInfo &configInfo) override;
	void prepare(IPAContext &context, const uint32_t frame,
		     IPAFrameContext &frameContext,
		     ipu3_uapi_params *params) override;
	void process(IPAContext &context, const uint32_t frame,
		     IPAFrameContext &frameContext,
		     const ipu3_uapi_stats_3a *stats,
		     ControlList &metadata) override;
	void queueRequest(IPAContext &context, const uint32_t frame,
			  IPAFrameContext &frameContext,
			  const ControlList &controls) override;

private:
	void afCoarseScan(IPAContext &context);
	void afFineScan(IPAContext &context);
	bool afScan(IPAContext &context, int min_step);
	void afReset(IPAContext &context);
	bool afNeedIgnoreFrame();
	void afIgnoreFrameReset();
	double afEstimateVariance(Span<const y_table_item_t> y_items, bool isY1);
	bool afIsOutOfFocus(IPAContext &context);

	/* ---- 2026-08-08 全新: 三模式状态机 ---- */
	void startAutoScan(IPAContext &context);
	void autoScanCoarse(IPAContext &context);
	void autoScanFine(IPAContext &context);
	void autoScanConfirmPeak(IPAContext &context);

	/* VCM step configuration. It is the current setting of the VCM step. */
	uint32_t focus_;
	/* The best VCM step. It is a local optimum VCM step during scanning. */
	uint32_t bestFocus_;
	/* Current AF statistic variance. */
	double currentVariance_;
	/* The frames are ignore before starting measuring. */
	uint32_t ignoreCounter_;
	/* It is used to determine the derivative during scanning */
	double previousVariance_;
	/* The designated maximum range of focus scanning. */
	uint32_t maxStep_;
	/* If the coarse scan completes, it is set to true. */
	bool coarseCompleted_;
	/* If the fine scan completes, it is set to true. */
	bool fineCompleted_;

	/* ---- 2026-08-08 全新成员 ---- */
	/* 当前模式: 0=manual 1=auto 2=continuous (libcamera controls::AfMode) */
	int32_t afMode_;
	/* 触发扫描请求 (controls::AfTrigger Start) */
	bool afTriggered_;
	/* manual 模式的 lens position (dioptre) */
	float lensPosition_;
	/* auto 锁定 (扫描完成后保持, 直到重新触发) */
	bool locked_;
	/* 粗扫阶段 (auto): 全范围 0→1023 记录最大方差位置 */
	bool forceScan_;
	uint32_t forceScanStep_;
	double forceBestVariance_;
	uint32_t forceBestFocus_;
	/* 细扫阶段 (auto): 在粗扫最佳点邻域 ±kFineRange 精修 */
	bool fineScan_;
	int32_t fineScanStep_;
	int32_t fineScanRange_;
	double fineBestVariance_;
	uint32_t fineBestFocus_;
	/* 峰值确认 (C3): 粗扫结束回退 1 步再采方差确认 */
	bool confirmPeak_;
	uint32_t confirmPeakFocus_;
	/* ⚠️ 2026-08-08: 确认失败 rescan 计数上限 (防低对比度无限循环) */
	uint32_t rescanCount_;
	/* ⚠️ 2026-08-08: auto idle 帧计数 (AfTrigger 丢失兜底超时) */
	uint32_t autoIdleFrames_;
	/* ⚠️ 2026-08-08: 历史全局最佳 (跨 rescan 保留, 防最后锁定在
	 * 最后一次 rescan 的次优 best) */
	uint32_t bestFocusAll_;
	double bestVarianceAll_;
	/* ⚠️ 2026-08-08: 细扫固定起点 (轨迹基准 — 扫描中 fineBestFocus_
	 * 会更新, 不能当轨迹基准, 否则轨迹漂移/跳变) */
	int32_t fineScanStart_;
	/* ⚠️ 2026-08-08: 失焦连续帧计数 (防单帧噪声误判重扫) */
	uint32_t outOfFocusFrames_;
	/* ⚠️ 2026-08-08: 扫描后基准收敛期计数 (EMA 收敛, 防峰值低估误判) */
	uint32_t baselineFrames_;
	/* settle 等待: 镜头移动后等待 N 帧再采统计 (帧计数=时间, 抗负载) */
	uint32_t settleFrames_;
	/* 方差滑动平均 (C2): 3 帧 EMA, 抗低光噪声 */
	double smoothedVariance_;
};

} /* namespace ipa::ipu3::algorithms */

} /* namespace libcamera */
