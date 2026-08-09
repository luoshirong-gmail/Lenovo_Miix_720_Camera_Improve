# OV5670 调校资产 (tuning)

画质调校相关文件，全部从公开渠道获取（Apache 2.0 许可，可自由使用/再分发）。

## 文件

| 文件 | 内容 | 来源 | 许可 |
|---|---|---|---|
| `ov5670.yaml` | **自制 libcamera tuning**（当前生效）：设置 `Agc.relativeLuminanceTarget: 0.35`（默认 0.16 画面暗，实测提亮 3 倍） | 本项目编写 | CC0-1.0 |
| `01ov5670.aiqb` | **Intel 官方 AIQ 3A 调校**（黑电平/增益/AWB/CCM/NR/LSC 全套，2017 IQStudio 调校，滤波器 SKL_2015ww22a） | ChromeOS `cros-camera-hal-configs-poppy` (board-overlays) `tuning_files/` | Apache-2.0 |
| `graph_settings_ov5670.xml` | Intel ImgU 管线配置 + sensor 模式（Bayer=GRBG、默认增益/曝光，1555 行） | ChromeOS 同仓库 `gcss/` | Apache-2.0 |

## 来源

- ChromeOS board-overlays 仓库:
  `https://chromium.googlesource.com/chromiumos/overlays/board-overlays/+/master/baseboard-poppy/media-libs/cros-camera-hal-configs-poppy/files/`
- Intel 官方: `https://github.com/intel/intel-ipu3-pipecfg`

## 说明

- `ov5670.yaml` 安装到 `/usr/share/libcamera/ipa/ipu3/ov5670.yaml` 即生效
  （IPA 启动时按传感器名加载，日志 "Using tuning file .../ov5670.yaml"）。
- `01ov5670.aiqb` 是 Intel 私有二进制格式，libcamera 开源 IPA 无法直接加载；
  需集成 Intel 3A 库（ChromeOS 的 libiaimaging，Apache 许可）或逆向提取参数。
