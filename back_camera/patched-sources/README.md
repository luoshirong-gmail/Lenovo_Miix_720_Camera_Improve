# 已修改源码归档 (patched-sources)

**用途**: 保留**修改后的源码**（非补丁），供将来比对分析、问题排查、补丁重建。
原始版本（未修改）见下方"来源"；修改版本与原始版本的差异即 `ipa-patches/`、
`gst-patches/`、`common/v4l2loopback-patches/` 中的补丁。

## 文件清单

| 文件 | 来源（原始） | 修改内容 | 对应补丁 |
|---|---|---|---|
| `ipu3-ipa/af.cpp` | libcamera 0.7.0 `src/ipa/ipu3/algorithms/af.cpp` | 三模式对焦状态机：失焦判定（归一化方差/自适应基准/连续确认/收敛期）、auto 扫描（细扫固定轨迹/历史最佳/rescan limit 细扫）、auto idle 兜底 | `ipa-patches/0001-af-ipu3.patch` |
| `ipu3-ipa/af.h` | libcamera 0.7.0 `src/ipa/ipu3/algorithms/af.h` | 新增成员 `outOfFocusFrames_`/`baselineFrames_`/`bestFocusAll_`/`bestVarianceAll_`/`fineScanStart_` | `ipa-patches/0002-af-ipu3-h.patch` |
| `gstreamer/gstlibcamera-controls.cpp` | libcamera 0.7.0 构建产物（由 `gstlibcamera-controls.cpp.in` 生成） | AF 控件属性（af-mode/af-trigger）已在官方 0.7 支持；本文件含验证期 AFDBG 调试日志（**临时**，发布部署前应还原官方干净版） | 无（官方已支持，见 `gst-patches/README.md`） |
| `v4l2loopback/v4l2loopback.c` | v4l2loopback 0.15.4 官方 | D-1+HERMES+MIN-3+IMAGE-ON-DEMAND + 写端解耦三件套 (HERMES-PATCH-3/4/5) + AF 控件（6 处 HERMES-PATCH 标记） | `common/v4l2loopback-patches/` |

## 比对方法

```bash
# 与原始版比对（以 IPA af.cpp 为例）
# 原始版: libcamera 0.7.0 官方源码（apt source / 官方发布包）
diff -u <原始路径>/af.cpp back_camera/patched-sources/ipu3-ipa/af.cpp
# 或用归档补丁重建修改版:
patch -p1 < back_camera/ipa-patches/0001-af-ipu3.patch   # 在原始源码根目录
```

## 注意

- `gstreamer/gstlibcamera-controls.cpp` 是**构建生成物**（configure 展开
  `.cpp.in` 模板），官方源模板为 `gstlibcamera-controls.cpp.in`；保留此
  生成物仅因验证期改动在其中（AFDBG），供排查参考。
- 修改版源码的**许可遵循其原始项目**（libcamera: LGPL-2.1+；v4l2loopback: GPL-2.0）。
