# IPU3 IPA 补丁 (自动对焦)

针对 libcamera 0.7.0 (Ubuntu) 源码 `src/ipa/ipu3/algorithms/` 的改动。

## 文件

| 补丁 | 目标文件 | 行数 | 说明 |
|---|---|---|---|
| `0001-af-ipu3.patch` | `af.cpp` | 651 | 三模式状态机增强：失焦判定（归一化方差/连续确认/自适应基准/收敛期）、auto 扫描精度（细扫固定轨迹/历史最佳/rescan limit 细扫）、auto idle 兜底 |
| `0002-af-ipu3-h.patch` | `af.h` | 99 | 新增成员：`outOfFocusFrames_`、`baselineFrames_`、`bestFocusAll_`、`bestVarianceAll_`、`fineScanStart_` |

## 应用

```bash
# 以 libcamera 源码根目录为基准
patch -p1 < 0001-af-ipu3.patch
patch -p1 < 0002-af-ipu3-h.patch
```

补丁为 `a/ b/` 相对路径格式（git apply / patch -p1 均可用，已验证 dry-run）。

## 构建

```bash
meson setup build -Dipas=ipu3
ninja -C build src/ipa/ipu3/ipa_ipu3.so
sudo cp build/src/ipa/ipu3/ipa_ipu3.so /usr/lib/x86_64-linux-gnu/libcamera/ipa/
```

## 行为说明

详见 `docs/ov5670-autofocus.md`（修复清单 B/C 部分）。
