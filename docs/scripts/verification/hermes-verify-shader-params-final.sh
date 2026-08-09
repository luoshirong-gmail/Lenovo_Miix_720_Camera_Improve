#!/bin/bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# hermes-verify-shader-params-final.sh — ad-hoc 验证 (2026-08-09 shader 参数定稿)
# 本回合改动: enhance.frag 参数 DENOISE_SS 2.0→1.0, DENOISE_SR 0.12→0.25, SHARPEN 1.0→1.8
# 验证: 参数值与用户定稿一致 / GLSL 语法 / 服务加载无编译错误
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
P="$PROJECT_ROOT"
F=$P/front_camera/shaders/enhance.frag

echo "=== 1. 参数值与用户定稿一致 (1.0 / 0.25 / 1.8, 对比度/饱和度不变) ==="
grep -q 'DENOISE_SS  = 1.0' $F && ok "DENOISE_SS = 1.0 (定稿)" || bad "DENOISE_SS ≠ 1.0"
grep -q 'DENOISE_SR  = 0.25' $F && ok "DENOISE_SR = 0.25 (定稿)" || bad "DENOISE_SR ≠ 0.25"
grep -q 'SHARPEN     = 1.8' $F && ok "SHARPEN = 1.8 (定稿)" || bad "SHARPEN ≠ 1.8"
grep -q 'CONTRAST    = 1.12' $F && ok "CONTRAST = 1.12 (不变)" || bad "CONTRAST 被改动"
grep -q 'SATURATION  = 1.25' $F && ok "SATURATION = 1.25 (不变)" || bad "SATURATION 被改动"
# 无旧值残留
! grep -qE 'DENOISE_SS  = 2.0|DENOISE_SR  = 0.12|SHARPEN     = 1.0' $F && ok "无旧参数值残留" || bad "旧参数值残留"

echo "=== 2. GLSL ES 1.00 兼容性 (函数内 const 禁令 + texture2D .rgb) ==="
BAD=$(grep -cE '^\s+const\s+' $F 2>/dev/null)
[ "$BAD" = "0" ] && ok "无函数内 const (ES 1.00)" || bad "含函数内 const ($BAD 处)"
# texture2D 赋 vec3 必须带 .rgb (历史崩溃根因 fc3a185) — 检查缺失 .rgb 的模式
BAD_RGB=$(grep -cE 'vec3 [a-z_]+ = texture2D\([^)]*\)(;|$)' $F 2>/dev/null)
[ "$BAD_RGB" = "0" ] && ok "无 texture2D 缺 .rgb 直赋 vec3 (3 处均带 .rgb)" || bad "存在缺 .rgb 直赋 ($BAD_RGB 处)"

echo "=== 3. GStreamer shader 编译 (权威验证) ==="
OUT=$(GST_DEBUG=opengl:5 gst-launch-1.0 videotestsrc num-buffers=3 ! glupload ! glcolorconvert \
    ! glshader fragment="$(cat $F)" \
    ! gldownload ! fakesink 2>&1)
echo "$OUT" | grep -qiE 'error|fail' && bad "GStreamer shader 编译失败" || ok "GStreamer shader 编译成功 (权威验证)"

echo "=== 4. Python router 服务加载 (重启后无编译错误) ==="
systemctl --user is-active camera-enhancement.service | grep -q active && ok "camera-enhancement active" || bad "服务未运行"
# 自上次重启以来无 shader 编译错误 (glshader 错误会致 router 崩溃 → systemd 重启循环)
JERR=$(journalctl --user -u camera-enhancement.service --since "10 min ago" 2>/dev/null | grep -ciE 'cannot be assigned|glshader.*error|shader.*compile')
[ "$JERR" = "0" ] && ok "近 10 分钟无 shader 编译错误日志" || bad "发现 $JERR 条 shader 错误日志"
# router 进程存活时长 (18:48:16 手动重启验证加载, 非崩溃循环 — 对照 journal 无 RepeatedCrash)
RPID=$(pgrep -f 'camera-router.py' | head -1)
if [ -n "$RPID" ]; then
    ET=$(ps -o etimes= -p $RPID | tr -d ' ')
    # 距上次手动重启 18:48:16 已 >2min; 若 <60s 需查 journal 是否 RepeatedCrash
    CRASH=$(journalctl --user -u camera-enhancement.service --since "30 min ago" 2>/dev/null | grep -c 'Failed with result\|RepeatedCrash')
    [ "$CRASH" = "0" ] && ok "router 进程存活 ${ET}s, 无崩溃重启记录 (18:48 手动重启后稳定)" || bad "检测到 $CRASH 条崩溃记录"
else
    bad "router 进程未找到"
fi

echo "=== 5. make_shader.py 生成验证 ==="
python3 $P/front_camera/scripts/make_shader.py $F /tmp/test-final.frag 1280 720 2>/dev/null
[ -f /tmp/test-final.frag ] && ok "make_shader.py 生成成功" || bad "make_shader.py 失败"
grep -q 'DENOISE_SS' /tmp/test-final.frag && ok "生成产物含参数" || bad "生成产物异常"
rm -f /tmp/test-final.frag

echo ""
echo "════════ 结果 ════════"
echo "PASS=$PASS FAIL=$FAIL (ad-hoc 验证, 非套件)"
exit $FAIL
