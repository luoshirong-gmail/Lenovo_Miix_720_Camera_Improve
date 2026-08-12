/* SPDX-License-Identifier: LGPL-2.1-or-later */
/*
 * Copyright (C) 2023, Collabora Ltd.
 *     Author: Nicolas Dufresne <nicolas.dufresne@collabora.com>
 *
 * GStreamer Camera Controls
 */

#pragma once

#include <memory>

#include <libcamera/camera.h>
#include <libcamera/controls.h>
#include <libcamera/request.h>

#include <mutex>

#include "gstlibcamerasrc.h"

namespace libcamera {

class GstCameraControls
{
public:
	static void installProperties(GObjectClass *klass, int lastProp);

	bool getProperty(guint propId, GValue *value, GParamSpec *pspec);
	bool setProperty(guint propId, const GValue *value, GParamSpec *pspec);

	void setCamera(const std::shared_ptr<libcamera::Camera> &cam);

	void applyControls(std::unique_ptr<libcamera::Request> &request);
	/* ⚠️ 2026-08-10 (ENOBUFS 修复): 带控件的 request 因 buffer 池不足
	 * 被丢弃时, 把控件放回 controls_ (下次 request 自动带上) —
	 * 事件驱动的控件 (af-mode/af-trigger) 不能随 ENOBUFS 消失 */
	void retainControls(libcamera::Request *request);
	void readMetadata(libcamera::Request *request);
private:
	/* ⚠️ 2026-08-09 (竞态修复): setProperty (主循环线程) 与
	 * applyControls (streaming 线程) 无锁竞争 controls_ — merge+clear
	 * 窗口内写入的控件值被清空丢失 → IPA 收不到 af-trigger/lens-position
	 * (用户实测: 单次对焦/手动移镜偶发或持续无效)。加互斥锁串行化。 */
	std::mutex controls_mutex_;

	/* Supported controls and limits of camera. */
	ControlInfoMap capabilities_;
	/* Set of user modified controls. */
	ControlList controls_;
	/* Accumulator of all controls ever set and metadata returned by camera */
	ControlList controls_acc_;
};

} /* namespace libcamera */
