# GStreamer libcamerasrc 插件 (AF 属性)

## 背景

`libcamerasrc` 需要 `af-mode` / `af-trigger` / `lens-position` 属性才能把
对焦控制从 v4l2 层转发到 IPA。

## 状态 (2026-08-08)

- libcamera 0.7.0 官方 gst 插件**已支持** AF 控件属性（`af-mode`/`af-trigger`
  的 GObject 属性注册 + controls 映射，见 `gstlibcamera-controls.cpp` 的
  `TYPE_AF_MODE` / `TYPE_AF_TRIGGER` 枚举注册与 `lastPropId + controls::AF_MODE`
  属性表）。
- 本项目验证过程中的调试日志（AFDBG fprintf）为**临时改动**，仅存在于构建产物
  （`build-new/src/gstreamer/gstlibcamera-controls.cpp`），未同步回源模板
  （`.cpp.in`），**不归档**（发布/部署前应还原为官方干净版）。

## 验证证据

- `AFDBG: setProperty propId=33 caps_empty=0`（propId 33 = controls::AF_MODE）
- `AFDBG: AF_MODE val=1`（setProperty 完整执行）

即属性路径：`g_object_set("af-mode") → setProperty → controls_[AfMode] →
applyControls merge → request → IPA queueRequest` 全程可用。

## 结论

gst 插件层**无需补丁**（官方 0.7 已支持）。如需自定义（如增加属性映射），
改动位置为 `src/gstreamer/gstlibcamera-controls.cpp.in`（源模板）与
`gstlibcamerasrc.cpp`。
