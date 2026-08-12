# libcamera 构建源码归档 (build-sources)

**来源**: 原位于 `/tmp/`（系统重启会重置），2026-08-08 归档至此。
**用途**: 重编译 IPA / gst 插件（修改 tuning 参数、再调校时需要）。

## 文件

| 文件 | 内容 | 大小 |
|---|---|---|
| `libcamera-orig.tar.gz` | libcamera 0.7.0 **修改版**完整源码树（含 build-new 构建配置，IPA/gst 改动已应用） | ~60M |
| `libcamera-vanilla.tar.gz` | libcamera 0.7.0 **原始**源码树（补丁基准，比对用） | ~10M |

## 解压与重建

```bash
mkdir -p ~/libcamera-build && cd ~/libcamera-build
tar xzf libcamera-orig.tar.gz
cd libcamera-orig/src/build-new
ninja src/ipa/ipu3/ipa_ipu3.so        # 重编译 IPA
ninja src/gstreamer/libgstlibcamera.so # 重编译 gst 插件
# 安装见 back_camera/scripts/install_af.sh (IPA_SRC/GST_SRC 指向构建产物)
```

## 与归档补丁的关系

- 修改版源码树 = 原始 + `ipa-patches/` 补丁（重建补丁基线：`libcamera-vanilla.tar.gz`）
- 单独文件级修改版: `patched-sources/`（af.cpp/af.h/gstlibcamera-controls.cpp）
- 比对: 见 `patched-sources/README.md`

**注意**: 本目录为构建资产（大文件），**不提交 git**（.gitignore 排除）。
