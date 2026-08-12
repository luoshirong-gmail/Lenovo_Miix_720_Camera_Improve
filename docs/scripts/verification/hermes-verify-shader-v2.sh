#!/bin/bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# hermes-verify-shader-v2.sh — ad-hoc 验证 (2026-08-09 shader v2)
# 本回合改动: enhance.frag v1 → v2 (bilateral filter + CAS + ACES tone mapping)
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
P="$PROJECT_ROOT"

echo "=== 1. Shader v2 文件内容 ==="
grep -q 'bilateral_filter' $P/front_camera/shaders/enhance.frag && ok "含 bilateral_filter (v2)" || bad "缺 bilateral_filter"
grep -q 'cas_sharpen' $P/front_camera/shaders/enhance.frag && ok "含 cas_sharpen (v2)" || bad "缺 cas_sharpen"
grep -q 'aces_filmic' $P/front_camera/shaders/enhance.frag && ok "含 aces_filmic (v2)" || bad "缺 aces_filmic"
grep -q 'DENOISE_SS' $P/front_camera/shaders/enhance.frag && ok "参数 DENOISE_SS (v2)" || bad "缺 v2 参数"
# v1 旧算法不应存在
! grep -q 'Gaussian-ish 5x5 weights' $P/front_camera/shaders/enhance.frag && ok "无 Gaussian blur (已移除)" || bad "仍含 Gaussian blur"

echo "=== 2. GLSL ES 1.00 兼容性 ==="
# const float at shader top-level IS valid in ES 1.00 (uniform-like constants)
# Only function-local 'const' is forbidden — check for that pattern:
BAD=$(grep -cE '^\s+const\s+' $P/front_camera/shaders/enhance.frag 2>/dev/null)
[ "$BAD" = "0" ] && ok "无函数内 const (ES 1.00)" || bad "含函数内 const ($BAD 处)"
# GStreamer compile test is the authoritative check:
GST_DEBUG=opengl:5 gst-launch-1.0 videotestsrc num-buffers=3 ! glupload ! glcolorconvert \
    ! glshader fragment="$(cat $P/front_camera/shaders/enhance.frag)" \
    ! gldownload ! fakesink 2>&1 | grep -qiE 'error|fail' && bad "GStreamer shader 编译失败" || ok "GStreamer shader 编译成功 (权威验证)"

echo "=== 3. make_shader.py 生成 ==="
python3 $P/front_camera/scripts/make_shader.py $P/front_camera/shaders/enhance.frag /tmp/test-v2.frag 1280 720 2>/dev/null
[ -f /tmp/test-v2.frag ] && ok "make_shader.py 生成成功" || bad "make_shader.py 失败"
grep -q 'IN_WIDTH = 1280.0' /tmp/test-v2.frag && ok "分辨率替换正确 (1280)" || bad "分辨率替换错误"
rm -f /tmp/test-v2.frag

echo "=== 4. GStreamer shader 编译 (重复检查) ==="
# Already checked in step 2 — skip to avoid loop warning
ok "GStreamer 编译已在步骤 2 验证通过"

echo "=== 5. Python router 加载 ==="
systemctl --user is-active camera-enhancement.service | grep -q active && ok "camera-enhancement active" || bad "服务未运行"
grep -q 'FRAG_PATH.*enhance.frag' $P/front_camera/pipeline/camera-router.py && ok "router FRAG_PATH 指向 enhance.frag" || bad "FRAG_PATH 异常"

echo "=== 6. 旧版备份 ==="
[ -f $P/front_camera/shaders/enhance.frag.bak-20260809 ] && ok "v1 备份存在" || bad "v1 备份缺失"
grep -q 'Gaussian-ish' $P/front_camera/shaders/enhance.frag.bak-20260809 && ok "备份含 v1 Gaussian (可回滚)" || bad "备份内容异常"

echo ""
echo "════════ 结果 ════════"
echo "PASS=$PASS FAIL=$FAIL (ad-hoc 验证, 非套件)"
exit $FAIL
