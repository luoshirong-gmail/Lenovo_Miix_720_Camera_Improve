# 系统回滚备份 (backups)

**来源**: 原位于 `/tmp/*.bak-*`（系统重启会重置），2026-08-08 归档至此。

## 文件

| 文件 | 说明 | 用途 |
|---|---|---|
| `ipa_ipu3.so.bak-9bcd5bbb` | **旧版 IPA**（9bcd5bbb，对焦修复前） | 系统 IPA 回滚点 |
| `libgstlibcamera.so.bak-1524` | **干净版 gst 插件**（无 AFDBG 调试日志） | 当前系统插件 = 此版（已还原） |

## 回滚方法

```bash
# IPA 回滚 (旧版)
sudo cp back_camera/backups/ipa_ipu3.so.bak-9bcd5bbb \
    /usr/lib/x86_64-linux-gnu/libcamera/ipa/ipa_ipu3.so
# gst 插件 (干净版)
sudo cp back_camera/backups/libgstlibcamera.so.bak-1524 \
    /usr/lib/x86_64-linux-gnu/gstreamer-1.0/libgstlibcamera.so
systemctl --user restart ov5670-virtual-camera.service
```

**注意**: 本目录为二进制资产，**不提交 git**（.gitignore 排除）。
