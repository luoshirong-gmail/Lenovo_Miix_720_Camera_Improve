#!/bin/bash
# deploy-finalize.sh — 机制开发收尾部署 (用户在场 sudo)
# 1) 系统 yaml 同步 (env fallback 一致性 — 版本统一)
# 2) daemon-reload + 重启服务 (服务文件已清理临时 Debug 日志)
# 3) 最终状态验证
set -e
P="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=== 1. 系统 yaml 同步 (与项目一致) ==="
sudo cp "$P/back_camera/tuning/ov5670.yaml" /usr/share/libcamera/ipa/ipu3/ov5670.yaml
sudo cp "$P/back_camera/tuning/README.md" /usr/share/libcamera/ipa/ipu3/ 2>/dev/null || true
diff -q "$P/back_camera/tuning/ov5670.yaml" /usr/share/libcamera/ipa/ipu3/ov5670.yaml && echo "yaml 同步 OK"

echo "=== 2. 服务重启 (服务文件变更生效) ==="
systemctl --user daemon-reload
systemctl --user restart ov5670-virtual-camera.service
sleep 4
systemctl --user is-active ov5670-virtual-camera.service

echo "=== 3. 最终验证 ==="
bash /tmp/hermes-verify-arch.sh
echo
echo "=== 4. 运行状态确认 ==="
journalctl --user -u ov5670-virtual-camera.service --since "10 seconds ago" --no-pager 2>/dev/null | grep -E "tuning file|IPU3Ccm|IPU3Awb" | head -4
md5sum /usr/lib/x86_64-linux-gnu/libcamera/ipa/ipa_ipu3.so /tmp/ipa_ipu3_arch_std.so | awk '{print $1}' | uniq -c
echo
echo "✅ 部署收尾完成 — 机制全部就绪, 参数调优待明天"
