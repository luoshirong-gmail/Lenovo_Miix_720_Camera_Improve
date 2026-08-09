#!/bin/bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# hermes-verify-af-clean.sh — 新鲜验证: DEBUG 日志移除后 router 激活/供帧/释放 全链路
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
LOG=/tmp/ov5670-router.log
cd "$PROJECT_ROOT"/back_camera/scripts

echo "=== 1. 编译 + 无 DEBUG 残留 ==="
if gcc -O2 -Wall -o ov5670-router ov5670-router.c $(pkg-config --cflags --libs gstreamer-1.0) -lpthread 2>/dev/null; then
  ok "gcc 编译通过"
else
  bad "编译失败"; echo "PASS=$PASS FAIL=$FAIL"; exit 1
fi
grep -q 'DEBUG:' ov5670-router.c && bad "DEBUG 残留" || ok "无 DEBUG 残留"

echo "=== 2. 服务重启 ==="
systemctl --user restart ov5670-virtual-camera.service
sleep 5
[ "$(systemctl --user is-active ov5670-virtual-camera.service)" = "active" ] && ok "服务 active" || bad "服务未启动"

echo "=== 3. 激活 → 实时帧 → 释放 全链路 ==="
timeout 10 v4l2-ctl -d /dev/video16 --stream-mmap --stream-count=100 > /dev/null 2>&1 &
sleep 4
grep -q '已激活 (cam PLAYING' "$LOG" && ok "reader 触发激活" || bad "未激活"
timeout 6 v4l2-ctl -d /dev/video16 --stream-mmap --stream-count=5 --stream-to=/tmp/afv16b.yuv >/dev/null 2>&1
SZ=$(stat -c%s /tmp/afv16b.yuv 2>/dev/null || echo 0)
[ "$SZ" -gt 30000000 ] && ok "video16 实时帧 ($SZ B)" || bad "帧不足 ($SZ B)"
rm -f /tmp/afv16b.yuv
sleep 3
grep -q '已释放 (cam PAUSED' "$LOG" && ok "释放 PAUSED (按需)" || bad "未释放"

echo ""
echo "════════ 结果 ════════"
echo "PASS=$PASS FAIL=$FAIL (ad-hoc 验证, 非套件)"
exit $FAIL
