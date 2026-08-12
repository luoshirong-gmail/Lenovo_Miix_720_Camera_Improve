# ipu3-ipa 修改版源码 (patched-sources)

libcamera IPU3 IPA 算法的**修改版**源码。基于 libcamera v0.7.0 原版修改，
用于部署自编译 IPA（`/usr/lib/x86_64-linux-gnu/libcamera/ipa/ipa_ipu3.so`）。

## 修改清单 (2026-08-11)

| 文件 | 修改 | 机制 (yaml 配置化) |
|---|---|---|
| `algorithms/awb.cpp/h` | Awb 增加 `init()` 读 tuning yaml | `redCompensation`/`blueCompensation` (Grey World 统计偏差非线性补偿, 缺省 1.0=原行为); `bnr.lut` 32 值 (降噪强度, 缺省=imguCssBnrDefaults) |
| `algorithms/ccm.cpp/h` | **新增**独立 Ccm 算法 (对齐 rkisp1 标准 `ccms` 格式) | `ccms: [{ct, ccm 3x3, offsets 3}]` 色温表, 取第一个条目; 缺省单位矩阵 (8191=1.0 s16 定点) |
| `algorithms/lsc.cpp/h` | **新增**Lsc 算法 (SHD 硬件) | `gridWidth/gridHeight/blockWidthLog2/blockHeightLog2/xStart/yStart/gains` (折叠标量逗号分隔 — 避开 yaml list 上限) |
| `algorithms/meson.build` | 注册 ccm.cpp + lsc.cpp | — |

## 运行 tuning 文件

服务通过 `LIBCAMERA_IPU3_TUNING_FILE` 指向
`back_camera/tuning/ov5670.yaml` (项目=运行, 版本统一)。
tuning 各段格式见 `back_camera/tuning/README.md`。

## 编译部署

```bash
cd <libcamera 源码>/build && ninja src/ipa/ipu3/ipa_ipu3.so
sudo cp src/ipa/ipu3/ipa_ipu3.so /usr/lib/x86_64-linux-gnu/libcamera/ipa/ipa_ipu3.so
systemctl --user restart ov5670-virtual-camera.service
```
