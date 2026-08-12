/* SPDX-License-Identifier: LGPL-2.1-or-later */
/*
 * Copyright (C) 2021, Red Hat
 *
 * IPU3 Af algorithm
 *
 * ⚠️ 2026-08-08 (全新重做, 基于原版 0.7.0 + 用户批准的设计):
 *   三模式状态机 (manual/auto/continuous) + settle 帧计数补偿
 *   (C1' 条件等待 / C2 方差平滑 / C3 峰值回步确认 / C4 细扫降速)
 *
 * 时序误差分析结论 (2026-08-08 论证):
 *   - AF 统计与镜头实际位置存在固定管线延迟 (1帧) + VCM settle 延迟
 *     (10-30ms), 帧率 29fps 硬件节拍 → 帧计数等待 = 时间等待, 抗 CPU 负载
 *   - 负载只影响 process() 调度及时性 (决策顺延), 统计本身由硬件帧同步
 *     保证正确 (DelayedControls 按 sequence 对齐)
 */

#include <cmath>
#include <limits.h>
#include <stdint.h>

#include <libcamera/base/log.h>
#include <libcamera/base/utils.h>

#include <libcamera/control_ids.h>
#include <libcamera/controls.h>

#include "af.h"

/**
 * \file af.h
 * \brief IPU3 AF control algorithm
 */

using namespace libcamera;

using namespace std::literals::chrono_literals;

namespace libcamera {

namespace ipa::ipu3::algorithms {

LOG_DEFINE_CATEGORY(IPU3Af)

/* AF 统计网格硬件限制 (原版 0.7.0, configure 中使用) */
static constexpr uint8_t kAfMinGridWidth = 16;
static constexpr uint8_t kAfMinGridHeight = 16;
static constexpr uint8_t kAfMaxGridWidth = 32;
static constexpr uint8_t kAfMaxGridHeight = 24;
static constexpr uint16_t kAfMinGridBlockWidth = 4;
static constexpr uint16_t kAfMinGridBlockHeight = 3;
static constexpr uint16_t kAfMaxGridBlockWidth = 6;
static constexpr uint16_t kAfMaxGridBlockHeight = 6;
static constexpr uint16_t kAfDefaultHeightPerSlice = 2;

/**
 * Maximum focus steps of the VCM control
 * \todo should be obtained from the VCM driver
 */
static constexpr uint32_t kMaxFocusSteps = 1023;

/*
 * ⚠️ 2026-08-08 (v3 参数): 用户实测反馈"扫描慢" → 加速:
 * kCoarseSearchStep 10→20 — 全范围扫描 ~4s→~2s (51 步 × 1帧 + settle)。
 * 粗扫步进 20 → best 偏差 ±20, 细扫范围 ±51 (kFineRange 0.05) 仍覆盖。
 * kFineSearchStep 1→2 — 细扫 102→51 步, ~10.6s→~5.3s (锁定 ±2 步精度,
 * 峰值区域平滑, 采样间隔 2 不丢失峰值)。
 */
static constexpr uint32_t kCoarseSearchStep = 20;
static constexpr uint32_t kFineSearchStep = 2;

/* Max ratio of variance change, 0.0 < kMaxChange < 1.0
 * ⚠️ v4 (2026-08-08): 0.3→0.4 — 0.3 实测误触发频繁 (正常场景方差
 * 波动 20-40% 被误判失焦 → 对焦准确时反复重扫); 回调用户原始批准值
 * 0.4 (比官方 0.5 敏感 20%, 真实失焦方差显著下降仍可靠触发) */
static constexpr double kMaxChange = 0.4;

/* ⚠️ 2026-08-08: 失焦连续确认帧数 — afIsOutOfFocus 连续 ≥5 帧超阈值
 * (≈170ms) 才触发 afReset, 防单帧噪声/瞬时波动误判重扫 */
static constexpr uint32_t kOutOfFocusConfirmFrames = 5;

/* ⚠️ 2026-08-08: 扫描后基准收敛期帧数 — hill-climbing 扫描中方差快速
 * 变化, EMA (0.5/0.5) 滞后导致扫描峰值被低估; 扫描完成 (stable) 后
 * EMA 收敛到真实方差 → cur 显著 > max → 误判失焦反复重扫 (实测
 * ratio 5.2)。收敛期内 maxVariance 跟随 EMA, 不判定失焦。 */
static constexpr uint32_t kBaselineFrames = 10;

/* The numbers of frame to be ignored, before performing focus scan. */
static constexpr uint32_t kIgnoreFrame = 10;

/* Fine scan range 0 < kFineRange < 1 */
static constexpr double kFineRange = 0.05;

/* ⚠️ 2026-08-08 (settle 补偿, 用户批准 C1'/C4):
 * 镜头移动后等待的帧数 (29fps → 1帧≈34.5ms, 覆盖 VCM settle 10-30ms)
 *   - 粗扫单调上升段: 1 帧 (移动中方差趋势仍有效, 每步 2 帧 ≈ 7s)
 *   - 峰值邻域/方向反转: 2 帧 (判定点, 必须等稳定)
 *   - 细扫: 2 帧 (精度关键, 慢而稳)
 * 用帧计数而非时间: 帧率硬件节拍固定 → 天然抗 CPU 负载抖动 */
static constexpr uint32_t kSettleCoarseFrames = 1;
static constexpr uint32_t kSettlePeakFrames = 2;
static constexpr uint32_t kSettleFineFrames = 2;

/* ⚠️ 2026-08-08: 峰值确认失败最大重扫次数 (防低对比度无限循环) */
static constexpr uint32_t kMaxRescan = 1;

/* ⚠️ 2026-08-08: auto idle 超时帧数 (AfTrigger 因 request 传递丢失时的兜底:
 * auto 模式 idle 超过 ~700ms 且未收到 AfTrigger → 自动开始扫描) */
static constexpr uint32_t kAutoIdleTimeoutFrames = 20;

/* 方差滑动平均窗口 (C2, EMA 权重) */
static constexpr double kVarEmaAlpha = 0.5; /* var = 0.5*new + 0.5*old (≈3帧等效) */

/* Settings for IPU3 AF filter */
static struct ipu3_uapi_af_filter_config afFilterConfigDefault = {
	.y1_coeff_0 = { 0, 1, 3, 7 },
	.y1_coeff_1 = { 11, 13, 1, 2 },
	.y1_coeff_2 = { 8, 19, 34, 242 },
	.y1_sign_vec = 0x7fdffbfe,
	.y2_coeff_0 = { 0, 1, 6, 6 },
	.y2_coeff_1 = { 13, 25, 3, 0 },
	.y2_coeff_2 = { 25, 3, 177, 254 },
	.y2_sign_vec = 0x4e53ca72,
	.y_calc = { 8, 8, 8, 8 },
	.nf = { 0, 9, 0, 9, 0 },
};

/**
 * \class Af
 * \brief An auto-focus algorithm based on IPU3 statistics
 *
 * This algorithm is used to determine the position of the lens to make a
 * focused image. The IPU3 AF processing block computes the statistics that
 * are composed by two types of filtered value and stores in a AF buffer.
 * Typically, for a clear image, it has a relatively higher contrast than a
 * blurred one. Therefore, if an image with the highest contrast can be
 * found through the scan, the position of the len indicates to a clearest
 * image.
 */
Af::Af()
	: focus_(0), bestFocus_(0), currentVariance_(0.0), previousVariance_(0.0),
	  coarseCompleted_(false), fineCompleted_(false),
	  afMode_(controls::AfModeContinuous), afTriggered_(false),
	  lensPosition_(0.0f), locked_(false),
	  forceScan_(false), forceScanStep_(0), forceBestVariance_(0.0),
	  forceBestFocus_(0), fineScan_(false), fineScanStep_(0), fineScanRange_(0),
	  fineScanStart_(0), fineBestVariance_(0.0), fineBestFocus_(0),
  outOfFocusFrames_(0), baselineFrames_(0),
	  confirmPeak_(false), confirmPeakFocus_(0), rescanCount_(0),
	  autoIdleFrames_(0), bestFocusAll_(0), bestVarianceAll_(0.0),
	  settleFrames_(0),
	  smoothedVariance_(0.0)
{
}

/**
 * \brief Configure the Af given a configInfo
 * \param[in] context The shared IPA context
 * \param[in] configInfo The IPA configuration data
 * \return 0 on success, a negative error code otherwise
 */
int Af::configure(IPAContext &context, const IPAConfigInfo &configInfo)
{
	struct ipu3_uapi_grid_config &grid = context.configuration.af.afGrid;
	grid.width = kAfMinGridWidth;
	grid.height = kAfMinGridHeight;
	grid.block_width_log2 = kAfMinGridBlockWidth;
	grid.block_height_log2 = kAfMinGridBlockHeight;

	/* AF 统计 ROI: 中心区域 (原版 0.7.0) */
	Rectangle bds(configInfo.bdsOutputSize);
	Size gridSize(grid.width << grid.block_width_log2,
		      grid.height << grid.block_height_log2);
	Rectangle roi = gridSize.centeredTo(bds.center());
	Point start = roi.topLeft();

	/* x_start and y_start should be even */
	grid.x_start = utils::alignDown(start.x, 2);
	grid.y_start = utils::alignDown(start.y, 2);
	grid.y_start |= IPU3_UAPI_GRID_Y_START_EN;

	/* Initial max focus step */
	maxStep_ = kMaxFocusSteps;

	/* Initial frame ignore counter */
	afIgnoreFrameReset();

	/* Initial focus value */
	context.activeState.af.focus = 0;
	/* Maximum variance of the AF statistics */
	context.activeState.af.maxVariance = 0;
	/* The stable AF value flag. if it is true, the AF should be in a stable state. */
	context.activeState.af.stable = false;

	return 0;
}

/**
 * \copydoc libcamera::ipa::Algorithm::prepare
 */
void Af::prepare(IPAContext &context,
		 [[maybe_unused]] const uint32_t frame,
		 [[maybe_unused]] IPAFrameContext &frameContext,
		 ipu3_uapi_params *params)
{
	const struct ipu3_uapi_grid_config &grid = context.configuration.af.afGrid;
	params->acc_param.af.grid_cfg = grid;
	params->acc_param.af.filter_config = afFilterConfigDefault;

	/* Enable AF processing block */
	params->use.acc_af = 1;
}

/**
 * \brief AF coarse scan
 * \param[in] context The shared IPA context
 *
 * Find a near focused image using a coarse step. The step is determined by
 * kCoarseSearchStep.
 */
void Af::afCoarseScan(IPAContext &context)
{
	if (coarseCompleted_)
		return;

	if (afNeedIgnoreFrame())
		return;

	if (afScan(context, kCoarseSearchStep)) {
		coarseCompleted_ = true;
		context.activeState.af.maxVariance = 0;
		focus_ = context.activeState.af.focus -
			 (context.activeState.af.focus * kFineRange);
		context.activeState.af.focus = focus_;
		previousVariance_ = 0;
		maxStep_ = std::clamp(focus_ + static_cast<uint32_t>((focus_ * kFineRange)),
				      0U, kMaxFocusSteps);
	}
}

/**
 * \brief AF fine scan
 * \param[in] context The shared IPA context
 *
 * Find an optimum lens position with moving 1 step for each search.
 */
void Af::afFineScan(IPAContext &context)
{
	if (!coarseCompleted_)
		return;

	if (afNeedIgnoreFrame())
		return;

	if (afScan(context, kFineSearchStep)) {
		context.activeState.af.stable = true;
		fineCompleted_ = true;
		/* ⚠️ 2026-08-08: 扫描完成 → 基准收敛期 (EMA 滞后防护) */
		baselineFrames_ = kBaselineFrames;
	}
}

/**
 * \brief AF reset
 * \param[in] context The shared IPA context
 *
 * Reset all the parameters to start over the AF process.
 */
void Af::afReset(IPAContext &context)
{
	if (afNeedIgnoreFrame())
		return;

	context.activeState.af.maxVariance = 0;
	context.activeState.af.focus = 0;
	focus_ = 0;
	context.activeState.af.stable = false;
	ignoreCounter_ = kIgnoreFrame;
	previousVariance_ = 0.0;
	coarseCompleted_ = false;
	fineCompleted_ = false;
	maxStep_ = kMaxFocusSteps;
	locked_ = false;
	forceScan_ = false;
	fineScan_ = false;
	confirmPeak_ = false;
	settleFrames_ = 0;
	smoothedVariance_ = 0.0;
	outOfFocusFrames_ = 0;
	baselineFrames_ = 0;
}

/**
 * \brief AF variance comparison
 * \param[in] context The IPA context
 * \param[in] min_step The VCM movement step
 *
 * We always pick the largest variance to replace the previous one. The image
 * with a larger variance also indicates it is a clearer image than previous
 * one. If we find a negative derivative, we return immediately.
 *
 * \return True, if it finds a AF value.
 */
bool Af::afScan(IPAContext &context, int min_step)
{
	if (focus_ > maxStep_) {
		/* If reach the max step, move lens to the position. */
		context.activeState.af.focus = bestFocus_;
		return true;
	} else {
		/*
		 * Find the maximum of the variance by estimating its
		 * derivative. If the direction changes, it means we have
		 * passed a maximum one step before.
		 */
		if ((currentVariance_ - context.activeState.af.maxVariance) >=
		    -(context.activeState.af.maxVariance * 0.1)) {
			/*
			 * Positive and zero derivative:
			 * The variance is still increasing. The focus could be
			 * increased for the next comparison. Also, the max variance
			 * and previous focus value are updated.
			 */
			bestFocus_ = focus_;
			focus_ += min_step;
			context.activeState.af.focus = focus_;
			context.activeState.af.maxVariance = currentVariance_;
		} else {
			/*
			 * Negative derivative:
			 * The variance starts to decrease which means the maximum
			 * variance is found. Set focus step to previous good one
			 * then return immediately.
			 */
			context.activeState.af.focus = bestFocus_;
			return true;
		}
	}

	previousVariance_ = currentVariance_;
	LOG(IPU3Af, Debug) << " Previous step is "
			   << bestFocus_
			   << " Current step is "
			   << focus_;
	return false;
}

/**
 * \brief Determine the frame to be ignored
 * \return Return True if the frame should be ignored, false otherwise
 */
bool Af::afNeedIgnoreFrame()
{
	if (ignoreCounter_ == 0)
		return false;
	else
		ignoreCounter_--;
	return true;
}

/**
 * \brief Reset frame ignore counter
 */
void Af::afIgnoreFrameReset()
{
	ignoreCounter_ = kIgnoreFrame;
}

/**
 * \brief Estimate variance
 * \param[in] y_items The AF filter data set from the IPU3 statistics buffer
 * \param[in] isY1 Selects between filter Y1 or Y2 to calculate the variance
 *
 * Calculate the mean of the data set provided by \a y_item, and then calculate
 * the variance of that data set from the mean.
 *
 * The operation can work on one of two sets of values contained within the
 * y_item data set supplied by the IPU3. The two data sets are the results of
 * both the Y1 and Y2 filters which are used to support coarse (Y1) and fine
 * (Y2) calculations of the contrast.
 *
 * \return The variance of the values in the data set \a y_item selected by \a isY1
 */
double Af::afEstimateVariance(Span<const y_table_item_t> y_items, bool isY1)
{
	uint32_t total = 0;
	double mean;
	double var_sum = 0;

	for (auto y : y_items)
		total += isY1 ? y.y1_avg : y.y2_avg;

	mean = total / y_items.size();

	for (auto y : y_items) {
		double avg = isY1 ? y.y1_avg : y.y2_avg;
		var_sum += pow(avg - mean, 2);
	}

	/* ⚠️ 2026-08-08 (根治 continuous 误判重扫): 归一化方差 (var/mean²)
	 * — AE 增益变化时 mean→g·mean, var→g²·var, var/mean² 不变 → 方差
	 * 成为"曝光无关"的清晰度指标。实测 AE 漂移使绝对方差暴涨 6 倍
	 * (cur=70万 vs max=11万, ratio 5.2) → afIsOutOfFocus 误判失焦反复
	 * 重扫; 归一化后该漂移被消除。 */
	if (mean > 1e-6)
		return var_sum / y_items.size() / (mean * mean);
	return var_sum / y_items.size(); /* 全黑保护 */
}

/**
 * \brief Determine out-of-focus situation
 * \param[in] context The IPA context
 *
 * Out-of-focus means that the variance change rate for a focused and a new
 * variance is greater than a threshold.
 *
 * \return True if the variance threshold is crossed indicating lost focus,
 * false otherwise
 */
bool Af::afIsOutOfFocus(IPAContext &context)
{
	/* ⚠️ 2026-08-08: uint32_t → double — 归一化后方差为小数
	 * (0.002-0.2), uint32_t 截断使 diff 恒 0 → 失焦检测失效 */
	const double diff_var = std::abs(currentVariance_ -
					context.activeState.af.maxVariance);
	const double var_ratio = diff_var / context.activeState.af.maxVariance;

	LOG(IPU3Af, Debug) << "Variance change rate: "
			   << var_ratio
			   << " cur=" << currentVariance_
			   << " max=" << context.activeState.af.maxVariance
			   << " step=" << context.activeState.af.focus;

	if (var_ratio > kMaxChange) {
		return true;
	} else {
		/* ⚠️ 自适应基准 (2026-08-08): 未失焦时 maxVariance 缓慢跟随
		 * 当前方差 (0.95/0.05, 时间常数 ~0.7s) — 归一化只消除增益
		 * 缩放, 场景亮度/mean 变化仍会使基准漂移 → 慢漂移被跟随,
		 * 剧烈变化 (真失焦) rate 仍超阈值触发 */
		context.activeState.af.maxVariance =
			0.95 * context.activeState.af.maxVariance
			+ 0.05 * currentVariance_;
		return false;
	}
}

/**
 * \brief Parse request controls (AfMode/AfTrigger/LensPosition)
 * \param[in] context The shared IPA context
 * \param[in] frame The frame context sequence number
 * \param[in] frameContext The current frame context
 * \param[in] controls The controls for the request
 *
 * ⚠️ 2026-08-08 (全新): 三模式支持 — libcamerasrc 的 af-mode / af-trigger /
 * lens-position 属性经 controls 到达 IPA, 在这里解析并驱动状态机。
 */
void Af::queueRequest(IPAContext &context, [[maybe_unused]] const uint32_t frame,
		      [[maybe_unused]] IPAFrameContext &frameContext,
		      const ControlList &controls)
{
	/* AfMode: 0=manual 1=auto 2=continuous */
	if (controls.contains(controls::AfMode.id())) {
		int32_t mode = controls.get(controls::AfMode).value();
		if (mode != afMode_) {
			LOG(IPU3Af, Debug) << "AF mode: " << afMode_ << " -> " << mode;
			afMode_ = mode;
			/* 模式切换语义 (libcamera 规范):
			 * - 进入 manual: 停止所有扫描, 镜头由 LensPosition 控制
			 * - 进入 auto:   idle 等待 AfTrigger
			 * - 进入 continuous: 立即开始扫描 (原版行为)
			 * ⚠️ 2026-08-09 (用户要求·定稿): 切入 continuous **不立即
			 * 扫描** — 保留当前焦点/方差基准, 先失焦判断, 失焦才重扫。
			 * 理由: 手动调焦后切回连续, 立即扫描会推翻手动结果;
			 * 且 auto→continuous 回退 (用户批准方案 AfMode 仅 0/2,
			 * 无定时回退) 应保留对焦状态。maxVariance==0 (从未对焦)
			 * 时 afIsOutOfFocus 除零 → inf → 判失焦 → 触发首次扫描,
			 * 保证开机/初始仍会自动对焦。 */
			if (mode == controls::AfModeContinuous) {
				context.activeState.af.stable = true;
				/* 清扫描状态但不重置焦点/基准 */
				forceScan_ = false;
				fineScan_ = false;
				confirmPeak_ = false;
				autoIdleFrames_ = 0;
				/* 不设 baseline: 直接进失焦判断路径 */
			} else if (mode == controls::AfModeManual) {
				/* ⚠️ 2026-08-09 (用户要求·定稿): 不 afReset 归零 —
				 * 官方语义: manual 下镜头由 LensPosition 控制,
				 * 未设则保持当前位置。afReset 会把 focus 归 0,
				 * 导致单次对焦 (临时 auto+Start) 完成后切回
				 * manual 时对焦结果丢失。只清扫描状态。 */
				forceScan_ = false;
				fineScan_ = false;
				confirmPeak_ = false;
				afTriggered_ = false;
				context.activeState.af.stable = true;
			} else /* auto */ {
				afReset(context);
				context.activeState.af.stable = true; /* idle, 等触发 */
			}
		}
	}

	/* AfTrigger: 0=Start (触发扫描) */
	if (controls.contains(controls::AfTrigger.id())) {
		int32_t trig = controls.get(controls::AfTrigger).value();
		if (trig == controls::AfTriggerStart) {
			LOG(IPU3Af, Debug) << "AF trigger received";
			afTriggered_ = true;
			/* ⚠️ 2026-08-09 (重新对焦修复): 触发语义 = 强制重新扫描 —
			 * 必须解锁, 否则 auto 模式 locked_ 时 AfTriggerStart 被
			 * 770 行 if(locked_) break 忽略 → manual→auto 切换不
			 * 重新对焦 (用户实测)。锁定状态在触发时作废。 */
			locked_ = false;
			fineScan_ = false;
			forceScan_ = false;
			confirmPeak_ = false;
		}
	}

	/* LensPosition: manual 模式镜头位置 (dioptre) */
	if (controls.contains(controls::LensPosition.id())) {
		lensPosition_ = controls.get(controls::LensPosition).value();
		if (afMode_ == controls::AfModeManual) {
			/* dioptre → VCM step: 0(∞)→0, ~2.0D(最近)→1023 */
			uint32_t step = std::clamp(
				static_cast<uint32_t>(lensPosition_ / 2.0f * 1023.0f),
				0U, kMaxFocusSteps);
			focus_ = step;
			context.activeState.af.focus = step;
			LOG(IPU3Af, Debug) << "Manual lens position: "
					   << lensPosition_ << "D -> step " << step;
		}
	}
}

/**
 * \brief Start an auto-mode full scan (triggered)
 * \param[in] context The shared IPA context
 *
 * ⚠️ 2026-08-08 (全新): auto 模式触发后, 全范围 0→1023 粗扫记录最大
 * 方差位置, 再细扫精修, 完成后锁定 (locked_)。锁定期间不动作, 直到
 * 再次 AfTrigger (router 侧 30s 超时回退 continuous 由心跳控制)。
 */
void Af::startAutoScan(IPAContext &context)
{
	context.activeState.af.stable = false;
	locked_ = false;
	forceScan_ = true;
	forceScanStep_ = 0;
	forceBestVariance_ = 0.0;
	forceBestFocus_ = 0;
		fineScan_ = false;
		confirmPeak_ = false;
		rescanCount_ = 0;
		autoIdleFrames_ = 0;
		bestFocusAll_ = 0;
		bestVarianceAll_ = 0.0;
		focus_ = 0;
	context.activeState.af.focus = 0;
	context.activeState.af.maxVariance = 0;
	smoothedVariance_ = 0.0;
	/* 起点 settle: 镜头移到 0 后等稳定再采 */
	settleFrames_ = kIgnoreFrame;
	ignoreCounter_ = 0;
	LOG(IPU3Af, Debug) << "AF auto scan start (full range)";
}

/**
 * \brief Auto-mode coarse scan (full range 0→1023)
 * \param[in] context The shared IPA context
 *
 * 每 kCoarseSearchStep 步进, 移动后等 kSettleCoarseFrames 帧再采方差
 * (C1'), 记录全局最大方差位置。扫描结束进入峰值确认 (C3)。
 */
void Af::autoScanCoarse(IPAContext &context)
{
	if (settleFrames_ > 0) {
		settleFrames_--;
		return;
	}

	/* 当前帧方差 (镜头已稳定) 用于峰值记录 */
	if (currentVariance_ > forceBestVariance_) {
		forceBestVariance_ = currentVariance_;
		forceBestFocus_ = focus_;
	}
	/* ⚠️ 历史全局最佳 (跨 rescan 保留) */
	if (currentVariance_ > bestVarianceAll_) {
		bestVarianceAll_ = currentVariance_;
		bestFocusAll_ = focus_;
	}

	forceScanStep_ += kCoarseSearchStep;
	if (forceScanStep_ > kMaxFocusSteps) {
		/* 全范围扫完 → 峰值确认 (C3): 回退 1 步重采, 防 settle 假峰值 */
		forceScan_ = false;
		confirmPeak_ = true;
		confirmPeakFocus_ = forceBestFocus_;
		/* 回退到 best - 半步 (5 步, 2026-08-08: 原 10 步对尖锐峰误判
		 * 假峰值 → rescan 浪费; 半步仍在峰值邻域, 确认通过率大增) */
		uint32_t back = (forceBestFocus_ > kCoarseSearchStep / 2)
					? forceBestFocus_ - kCoarseSearchStep / 2 : 0;
		focus_ = back;
		context.activeState.af.focus = back;
		settleFrames_ = kSettlePeakFrames;
		LOG(IPU3Af, Debug) << "AF coarse done, best=" << forceBestFocus_
				   << " var=" << forceBestVariance_
				   << ", confirm at " << back;
		return;
	}

	focus_ = forceScanStep_;
	context.activeState.af.focus = forceScanStep_;
	/* C1': 单调上升段 1 帧 settle (移动中方差趋势仍有效) */
	settleFrames_ = kSettleCoarseFrames;
}

/**
 * \brief Auto-mode peak confirmation (C3)
 * \param[in] context The shared IPA context
 *
 * 粗扫结束后回退 1 步重采方差: 若仍 ≥ 记录的峰值方差, 确认峰值;
 * 否则在回退点重新搜索 (峰值可能更近)。确认后进入细扫 (C4)。
 */
void Af::autoScanConfirmPeak(IPAContext &context)
{
	if (settleFrames_ > 0) {
		settleFrames_--;
		return;
	}

		if (currentVariance_ >= forceBestVariance_ * 0.9) {
			/* 峰值确认 → 跳到最佳位置, settle 后细扫 */
			LOG(IPU3Af, Debug) << "AF peak confirmed at " << confirmPeakFocus_;
			/* ⚠️ 修复: 确认后必须清除, 否则 process 反复进 confirm 分支
			 * (9bcd5bbb 的确认循环 bug: 永不进细扫/锁定) */
			confirmPeak_ = false;
			focus_ = confirmPeakFocus_;
		context.activeState.af.focus = confirmPeakFocus_;
		/* 细扫范围: best ±5% 全行程 */
		fineScan_ = true;
		fineScanStep_ = 0;
		fineScanRange_ = static_cast<int32_t>(kMaxFocusSteps * kFineRange);
		fineBestVariance_ = 0.0;
		fineBestFocus_ = confirmPeakFocus_;
		/* 细扫起点: best - range (⚠️ 固定, 轨迹基准) */
		int32_t start = static_cast<int32_t>(confirmPeakFocus_) - fineScanRange_;
		fineScanStart_ = std::max(0, start);
		focus_ = fineScanStart_;
		context.activeState.af.focus = focus_;
		settleFrames_ = kSettleFineFrames;
		} else {
			/* 确认失败 (假峰值) → 重新全范围粗扫确认
			 * ⚠️ 2026-08-09 (用户实测·定稿): 曾改为 confirm 失败直接
			 * fine scan 历史最佳 — 但粗扫步长 (kCoarseSearchStep) 较大,
			 * best 可能偏离真实峰值, 细扫围绕错误位置 → 错过最清晰点
			 * (用户实测)。恢复 rescan: 重新全范围粗扫确认峰值, 上限
			 * kMaxRescan 次 (防无限循环; 之前"3-4 次全扫"是锁定后
			 * idle 循环重扫 (补丁③) 所致, 已撤销, 与 rescan 无关)。 */
			LOG(IPU3Af, Warning) << "AF peak confirm failed at "
					     << confirmPeakFocus_ << ", rescan";
			rescanCount_++;
			if (rescanCount_ > kMaxRescan) {
				/* 多次假峰值: 放弃重扫, 围绕历史全局最佳细扫收尾 */
				LOG(IPU3Af, Warning) << "AF rescan limit reached ("
						   << rescanCount_ << "), fine scan around "
						   << bestFocusAll_;
				confirmPeak_ = false;
				forceScan_ = false;
				fineScan_ = true;
				fineScanStep_ = 0;
				fineScanRange_ = static_cast<int32_t>(kMaxFocusSteps * kFineRange);
				fineBestVariance_ = 0.0;
				fineBestFocus_ = bestFocusAll_;
				int32_t fstart = static_cast<int32_t>(bestFocusAll_) - fineScanRange_;
				fineScanStart_ = std::max(0, fstart);
				focus_ = fineScanStart_;
				context.activeState.af.focus = focus_;
				settleFrames_ = kSettleFineFrames;
				return;
			}
			/* 重新全范围粗扫: 重新采样, 确认峰值非假峰 */
			LOG(IPU3Af, Warning) << "AF rescan (" << rescanCount_
					     << "), full coarse scan";
			forceScan_ = true;
			forceScanStep_ = 0;
			forceBestVariance_ = 0.0;
			forceBestFocus_ = 0;
			confirmPeak_ = false;
			focus_ = 0;
			context.activeState.af.focus = 0;
			settleFrames_ = kSettleCoarseFrames;
			return;
		}
}

/**
 * \brief Auto-mode fine scan (C4: 2 帧 settle)
 * \param[in] context The shared IPA context
 *
 * 在粗扫最佳点 ±kFineRange 范围内步进 1, 每步 settle 2 帧 (VCM 充分
 * 稳定), 记录最大方差位置, 完成后锁定。
 */
void Af::autoScanFine(IPAContext &context)
{
	if (settleFrames_ > 0) {
		settleFrames_--;
		return;
	}

	if (currentVariance_ > fineBestVariance_) {
		fineBestVariance_ = currentVariance_;
		fineBestFocus_ = focus_;
	}

	fineScanStep_ += kFineSearchStep;
	if (fineScanStep_ > fineScanRange_ * 2) {
		/* 细扫完成 → 锁定最佳位置 */
		focus_ = fineBestFocus_;
		context.activeState.af.focus = fineBestFocus_;
		context.activeState.af.maxVariance = fineBestVariance_;
		context.activeState.af.stable = true;
		fineScan_ = false;
		locked_ = true;
		/* ⚠️ 2026-08-09 (A 方案): continuous 复用本链后, 扫描完成直接进
		 * 失焦检测 → EMA 未收敛误判 → 加基准收敛期 (与 afFineScan 一致) */
		baselineFrames_ = kBaselineFrames;
		LOG(IPU3Af, Debug) << "AF locked at " << fineBestFocus_
				   << " (fine)";
		return;
	}

	/* 细扫轨迹: 固定起点 → +2*range (⚠️ 2026-08-08: 原用动态
	 * fineBestFocus_ 做基准, 扫描中更新导致轨迹漂移/跳变 → 锁定
	 * 到范围外的异常位置 (实测 154 vs 预期 360±51) */
	int32_t next = fineScanStart_ + fineScanStep_;
	focus_ = std::clamp(next, 0, static_cast<int32_t>(kMaxFocusSteps));
	context.activeState.af.focus = focus_;
	settleFrames_ = kSettleFineFrames;
}

/**
 * \brief Determine the max contrast image and lens position
 * \param[in] context The IPA context
 * \param[in] frame The frame context sequence number
 * \param[in] frameContext The current frame context
 * \param[in] stats The statistics buffer of IPU3
 * \param[out] metadata Metadata for the frame, to be filled by the algorithm
 *
 * Ideally, a clear image also has a relatively higher contrast. So, every
 * image for each focus step should be tested to find an optimal focus step.
 *
 * ⚠️ 2026-08-08 (全新): 三模式状态机。
 */
void Af::process(IPAContext &context, [[maybe_unused]] const uint32_t frame,
		 [[maybe_unused]] IPAFrameContext &frameContext,
		 const ipu3_uapi_stats_3a *stats,
		 [[maybe_unused]] ControlList &metadata)
{
	/* Evaluate the AF buffer length */
	uint32_t afRawBufferLen = context.configuration.af.afGrid.width *
				  context.configuration.af.afGrid.height;

	ASSERT(afRawBufferLen < IPU3_UAPI_AF_Y_TABLE_MAX_SIZE);

	Span<const y_table_item_t> y_items(reinterpret_cast<const y_table_item_t *>(&stats->af_raw_buffer.y_table),
					   afRawBufferLen);

	/*
	 * Calculate the mean and the variance of AF statistics for a given grid.
	 * For coarse: y1 are used.
	 * For fine: y2 results are used.
	 */
	currentVariance_ = afEstimateVariance(y_items, !coarseCompleted_);

	/* C2: 方差滑动平均 (EMA), 抗低光噪声 / settle 过渡帧抖动 */
	smoothedVariance_ = smoothedVariance_ == 0.0
				? currentVariance_
				: kVarEmaAlpha * currentVariance_
					+ (1.0 - kVarEmaAlpha) * smoothedVariance_;
	/* 状态机统一使用平滑方差 (峰值记录/判定) */
	currentVariance_ = smoothedVariance_;

	switch (afMode_) {
	case controls::AfModeManual: /* 0: manual — LensPosition 已在 queueRequest 处理 */
		/* 保持不动; 镜头位置由 queueRequest 中的 LensPosition 直接设置 */
		context.activeState.af.stable = true;
		/* ⚠️ 2026-08-10 (AfState 完成检测): manual → Idle */
		metadata.set(controls::AfState, controls::AfStateIdle);
		break;

	case controls::AfModeAuto: { /* 1: auto — 触发扫描 + 锁定 */
		if (afTriggered_) {
			afTriggered_ = false;
			autoIdleFrames_ = 0;
			startAutoScan(context);
		}
		if (locked_) {
			/* 锁定: 保持当前焦点, 等下一次 AfTrigger (773 行先于此处
			 * 处理, 触发即 startAutoScan 重新扫描 — 无需 idle 兜底)。
			 * ⚠️ 2026-08-09 (循环扫描修复): 曾在此加 20 帧 idle 兜底
			 * 重扫 → 锁定后 0.67s 强制重扫 → 40s 窗口内循环扫描
			 * 3-4 次 (用户实测"全扫描了 3-4 个全程")。撤销: 锁定
			 * 即稳定, 重扫只由用户 AfTrigger 触发。 */
			context.activeState.af.stable = true;
			/* AfState: 扫描完成锁定 → Focused */
			metadata.set(controls::AfState, controls::AfStateFocused);
			break;
		}
		if (confirmPeak_) {
			metadata.set(controls::AfState, controls::AfStateScanning);
			autoScanConfirmPeak(context);
			break;
		}
		if (forceScan_) {
			metadata.set(controls::AfState, controls::AfStateScanning);
			autoScanCoarse(context);
			break;
		}
		if (fineScan_) {
			metadata.set(controls::AfState, controls::AfStateScanning);
			autoScanFine(context);
			break;
		}
		/* ⚠️ 兜底 (2026-08-08): auto idle 超时 — AfTrigger 因 request
		 * 传递丢失 (gst 层 setProperty 与 applyControls 的 clear 竞争)
		 * 时自动开始扫描, 保证触发可靠 */
		if (++autoIdleFrames_ > kAutoIdleTimeoutFrames) {
			LOG(IPU3Af, Debug) << "AF auto idle timeout, scan";
			autoIdleFrames_ = 0;
			startAutoScan(context);
			metadata.set(controls::AfState, controls::AfStateScanning);
			break;
		}
		/* auto idle 未触发/未扫描 → Idle (等 AfTrigger) */
		metadata.set(controls::AfState, controls::AfStateIdle);
		break;
	}

	default: /* 2: continuous — ⚠️ 2026-08-09 (A 方案): 与 auto 同一套扫描链
		 * (原 hill climbing afCoarseScan/afFineScan 单调前进+首降即停,
		 * 局部峰/噪声误判 → 不准; 统一走 startAutoScan 全范围+confirm+细扫) */
		/* 扫描链状态优先 (由 startAutoScan 设置) */
		if (forceScan_) {
			metadata.set(controls::AfState, controls::AfStateScanning);
			autoScanCoarse(context);
			break;
		}
		if (confirmPeak_) {
			metadata.set(controls::AfState, controls::AfStateScanning);
			autoScanConfirmPeak(context);
			break;
		}
		if (fineScan_) {
			metadata.set(controls::AfState, controls::AfStateScanning);
			autoScanFine(context);
			break;
		}
		if (!context.activeState.af.stable) {
			/* 初始/扫描后未稳定 → 启动全范围扫描 */
			startAutoScan(context);
			metadata.set(controls::AfState, controls::AfStateScanning);
			break;
		}
		/* 稳定: 基准收敛期 — 扫描后 EMA 未收敛, maxVariance 跟随当前
		 * 方差 (0.5/0.5), 期间不判定失焦 (防 EMA 滞后误判重扫) */
		if (baselineFrames_ > 0) {
			baselineFrames_--;
			context.activeState.af.maxVariance =
				0.5 * context.activeState.af.maxVariance
				+ 0.5 * currentVariance_;
			outOfFocusFrames_ = 0;
			/* 稳定收敛中 → Focused */
			metadata.set(controls::AfState, controls::AfStateFocused);
			break;
		}
		/* 失焦检测 → 连续 ≥5 帧超阈值 → 全范围重扫 (与 auto 同链) */
		if (afIsOutOfFocus(context)) {
			if (++outOfFocusFrames_ >= kOutOfFocusConfirmFrames) {
				LOG(IPU3Af, Debug) << "AF out-of-focus confirmed ("
						   << outOfFocusFrames_ << " frames)";
				outOfFocusFrames_ = 0;
				startAutoScan(context);
				metadata.set(controls::AfState, controls::AfStateScanning);
			}
		} else {
			outOfFocusFrames_ = 0;
			afIgnoreFrameReset();
		}
		/* 稳定 (非失焦) → Focused */
		metadata.set(controls::AfState, controls::AfStateFocused);
		break;
	}
}

REGISTER_IPA_ALGORITHM(Af, "Af")

} /* namespace ipa::ipu3::algorithms */

} /* namespace libcamera */
