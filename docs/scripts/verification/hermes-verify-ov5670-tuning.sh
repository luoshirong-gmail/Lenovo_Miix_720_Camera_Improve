#!/bin/bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# hermes-verify-ov5670-tuning.sh — ad-hoc 验证 (2026-08-08 17:4x)
# 本回合改动: ①ov5670-tuning/ov5670.yaml (AGC relativeLuminanceTarget 0.35)
# ②/tmp/compare-v1v2.py (v1/v2 图像对比脚本)
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
YAML="$PROJECT_ROOT"/ov5670-tuning/ov5670.yaml
SYSYAML=/usr/share/libcamera/ipa/ipu3/ov5670.yaml
SVC=ov5670-virtual-camera.service

echo "=== 1. tuning 文件 (YAML 语法 + 内容) ==="
[ -f "$YAML" ] && ok "项目 ov5670.yaml 在位" || bad "项目 yaml 缺失"
[ -f "$SYSYAML" ] && ok "系统 yaml 在位 ($(stat -c%s "$SYSYAML") B)" || bad "系统 yaml 缺失"
env -u PYTHONPATH python3 -c "
import yaml
with open('$SYSYAML') as f:
    d = yaml.safe_load(f)
algs = [list(a.keys())[0] for a in d['algorithms']]
assert 'Agc' in algs, 'Agc 缺失'
agc = [a for a in d['algorithms'] if 'Agc' in a][0]
assert abs(agc['Agc']['relativeLuminanceTarget'] - 0.35) < 0.001, 'target 错误'
print('  YAML 解析 OK, algorithms:', algs)
print('  relativeLuminanceTarget =', agc['Agc']['relativeLuminanceTarget'])
" 2>/tmp/afv7_yaml.log && ok "YAML 语法 + target 0.35 正确" || bad "YAML 错误: $(cat /tmp/afv7_yaml.log | head -2)"

echo "=== 2. IPA 实际加载 tuning ==="
J=$(journalctl --user -u $SVC --since "-10min" --no-pager 2>/dev/null | grep -c 'Using tuning file /usr/share/libcamera/ipa/ipu3/ov5670.yaml')
[ "$J" -ge 1 ] && ok "IPA 加载 ov5670.yaml (journal 确认, $J 次)" || bad "未加载 tuning"
# 当前运行实例 (最近一次服务启动) 的 fallback 数 (tuning 安装后应为 0)
CUR=$(systemctl --user show $SVC -p ActiveEnterTimestamp | cut -d= -f2)
N=$(journalctl --user -u $SVC --since "$CUR" --no-pager 2>/dev/null | grep -c "ov5670.yaml' not found")
[ "$N" = "0" ] && ok "当前实例 0 次 fallback (自 $CUR)" || bad "当前实例仍有 fallback $N 次"

echo "=== 3. compare 脚本运行 + 提亮效果 ==="
OUT=$(env -u PYTHONPATH python3 /tmp/compare-v1v2.py 2>&1)
echo "$OUT" | grep -q '亮度=132.6' && ok "v2 亮度 132.6 (提亮生效)" || bad "v2 亮度异常"
echo "$OUT" | grep -q '亮度=43.5' && ok "v1 亮度 43.5 (对比基线)" || bad "v1 亮度异常"
B1=$(echo "$OUT" | grep -oE '亮度=[0-9.]+' | grep -oE '[0-9.]+' | sed -n '1p')
B2=$(echo "$OUT" | grep -oE '亮度=[0-9.]+' | grep -oE '[0-9.]+' | sed -n '2p')
echo "  v1=$B1 v2=$B2"
[ -n "$B1" ] && [ -n "$B2" ] && awk "BEGIN{exit !($B2 > 2*$B1)}" && ok "v2 > 2×v1 亮度 (提亮显著)" || bad "提亮不足"

echo "=== 4. 服务稳定 ==="
[ "$(systemctl --user is-active $SVC)" = "active" ] && ok "服务 active" || bad "服务异常"

echo ""
echo "════════ 结果 ════════"
echo "PASS=$PASS FAIL=$FAIL (ad-hoc 验证, 非套件)"
exit $FAIL
