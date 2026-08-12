#!/bin/bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# hermes-verify-af-build: OV5670 对焦优化代码变更验证 (ad-hoc, 非套件)
set -u
PASS=0; FAIL=0
ok()  { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

SCRIPTS="$PROJECT_ROOT"/back_camera/scripts
SRC=/tmp/libcamera-orig/src
echo "=== 1. P4: ov5670-router.c 编译 (对焦转发) ==="
cd $SCRIPTS
gcc -O2 -Wall -o /tmp/ov5670-router-af-test ov5670-router.c $(pkg-config --cflags --libs gstreamer-1.0) -lpthread 2>/tmp/af-gcc.log
[ $? -eq 0 ] && ok "编译 0 error" || { bad "编译失败"; head -5 /tmp/af-gcc.log; }
[ -f /tmp/ov5670-router-af-test ] && ok "二进制生成 ($(stat -c %s /tmp/ov5670-router-af-test) B)" || bad "无二进制"
grep -q 'AF: 对焦轮询启动\|af_poll_thread' ov5670-router.c && ok "对焦模块存在 (轮询/心跳/状态机)" || bad "对焦模块缺失"
grep -q 'AF_AUTO_LOCK_SECONDS 30' ov5670-router.c && ok "锁定 30s 参数在位" || bad "锁定参数缺失"
rm -f /tmp/ov5670-router-af-test

echo "=== 2. P1: v4l2loopback 对焦控件补丁脚本 (幂等+回滚+OV5670 条件) ==="
cp /usr/src/v4l2loopback-0.15.4/v4l2loopback.c /tmp/hermes-verify-v4l2.c
V4L2RC=$(python3 - << 'PYEOF'
import sys
sys.path.insert(0, ""$PROJECT_ROOT"/back_camera/scripts")
import patch_v4l2loopback_af as P
P.PATH = "/tmp/hermes-verify-v4l2.c"
r1 = P.apply()          # apply
r2 = P.check()          # 已应用
src_applied = open(P.PATH).read()
ov = 'strstr(dev->card_label, "OV5670")' in src_applied
r3 = P.revert()         # revert
r4 = P.check()          # 未应用 (rc=1)
src_clean = open(P.PATH).read()
clean = 'CID_FOCUS_AUTO' not in src_clean and 'ov5670-af-20260808' not in src_clean
print(f"OV5670条件={ov} 回滚干净={clean}")
sys.exit(0 if (r1==0 and r2==0 and r3==0 and r4==1 and ov and clean) else 1)
PYEOF
)
[ $? -eq 0 ] && ok "apply→check→revert→check 全流程 + OV5670 条件 + 回滚干净" || bad "补丁脚本流程异常"
rm -f /tmp/hermes-verify-v4l2.c

echo "=== 3. P5: install_af.sh 语法 + 安全性 + 修复点 ==="
bash -n $SCRIPTS/install_af.sh && ok "bash 语法通过" || bad "语法错误"
grep -qE 'sudo -S|/tmp/\.hermes-pw|printf.*password' $SCRIPTS/install_af.sh && bad "⚠️ 危险密码机制" || ok "无密码文件/管道传密 (安全)"
grep -q 'sudo dkms\|sudo rmmod\|sudo cp' $SCRIPTS/install_af.sh && ok "交互式 sudo 模式" || bad "sudo 调用缺失"
# 2026-08-08 修复点 (用户实测反馈)
grep -q 'dkms build -m v4l2loopback -v 0.15.4 --force' $SCRIPTS/install_af.sh && ok "修复①: dkms build --force (补丁进模块)" || bad "修复①缺失"
if grep -qE '^\s*sudo\s+.*sign-file' $SCRIPTS/install_af.sh; then bad "修复②: sign-file 实际代码仍残留"; else ok "修复②: 手动 sign-file 已删 (dkms 自动签名)"; fi
grep -q 'UCTL()' $SCRIPTS/install_af.sh && ok "修复③: systemctl --user 转 user bus (sudo 兼容)" || bad "修复③缺失"
grep -qE '^\s*sudo python3' $SCRIPTS/install_af.sh && ok "修复④: patch 脚本内部 sudo (非 sudo 用户可跑)" || bad "修复④缺失"

echo "=== 4. P2: IPA af.cpp 全新状态机 + 参数 ==="
AF=$SRC/src/ipa/ipu3/algorithms/af.cpp
[ -f "$AF" ] && ok "af.cpp 存在" || { bad "af.cpp 缺失"; }
grep -q 'kCoarseSearchStep = 10' $AF && ok "kCoarseSearchStep=10 (3.4s 扫描)" || bad "步进参数错误"
grep -q 'kMaxChange = 0.4' $AF && ok "kMaxChange=0.4 (40% 失焦阈值)" || bad "阈值参数错误"
grep -q 'kSettleCoarseFrames\|kSettlePeakFrames\|kSettleFineFrames' $AF && ok "settle 帧计数补偿 (C1'/C4)" || bad "settle 缺失"
grep -q 'smoothedVariance_' $AF && ok "方差 EMA 平滑 (C2)" || bad "C2 缺失"
grep -q 'confirmPeak_' $AF && ok "峰值回步确认 (C3)" || bad "C3 缺失"
grep -q 'AfModeManual\|AfModeAuto\|AfModeContinuous' $AF && ok "三模式状态机" || bad "状态机缺失"
grep -q 'queueRequest' $AF && ok "queueRequest 控件解析" || bad "queueRequest 缺失"

echo "=== 5. P3: gen-gst-controls AfTrigger ==="
grep -q 'AfTrigger' $SRC/utils/codegen/gen-gst-controls.py && ok "AfTrigger 已加入 exposed_controls" || bad "AfTrigger 缺失"

echo "=== 6. 编译产物 (P2/P3) ==="
[ -f $SRC/build-new/src/ipa/ipu3/ipa_ipu3.so ] && ok "ipa_ipu3.so ($(stat -c %s $SRC/build-new/src/ipa/ipu3/ipa_ipu3.so) B)" || bad "ipa_ipu3.so 缺失"
[ -f $SRC/build-new/src/gstreamer/libgstlibcamera.so ] && ok "libgstlibcamera.so ($(stat -c %s $SRC/build-new/src/gstreamer/libgstlibcamera.so) B)" || bad "libgstlibcamera.so 缺失"

echo ""
echo "════════ 结果 ════════"
echo "PASS=$PASS FAIL=$FAIL (ad-hoc 验证, 非套件; sudo 安装环节待用户执行)"
rm -f /tmp/af-gcc.log