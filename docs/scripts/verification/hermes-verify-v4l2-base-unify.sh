#!/bin/bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# hermes-verify-v4l2-base-unify.sh — ad-hoc 验证 (2026-08-09)
# 本回合变更: v4l2loopback base 统一 0xf000→0xf900 (项目内源码 + patch 脚本注释)
# 验证: 项目内源码已统一 / patch 脚本注释同步 / 与运行模块实测一致 / git 已提交
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
P="$PROJECT_ROOT"

echo "=== 1. 项目内两份 patched-sources base 已统一为 0xf900 ==="
F1=$P/back_camera/patched-sources/v4l2loopback.c
F2=$P/back_camera/patched-sources/v4l2loopback/v4l2loopback.c
grep -q 'V4L2_CID_USER_BASE | 0xf900' "$F1" && ok "patched-sources/v4l2loopback.c: base=0xf900" || bad "F1 base 未统一"
grep -q 'V4L2_CID_USER_BASE | 0xf900' "$F2" && ok "patched-sources/v4l2loopback/v4l2loopback.c: base=0xf900" || bad "F2 base 未统一"
! grep -q 'V4L2_CID_USER_BASE | 0xf000' "$F1" && ok "F1 无旧 0xf000 残留" || bad "F1 仍含 0xf000"
! grep -q 'V4L2_CID_USER_BASE | 0xf000' "$F2" && ok "F2 无旧 0xf000 残留" || bad "F2 仍含 0xf000"
# 官方值注释保留 (说明差异)
grep -q '官方上游 0.15.4 为 0xf000' "$F1" && ok "F1 保留官方值差异注释" || bad "F1 缺差异注释"

echo "=== 2. patch 脚本注释同步 (0x0098f004 → 0x0098f904) ==="
grep -q '0x0098f904' $P/back_camera/scripts/patch_v4l2loopback_af.py && ok "patch 脚本注释含 0x0098f904" || bad "patch 脚本未更新"
# 0x0098f004 仅允许出现在"非 0x0098f004"历史对照说明中; 禁止出现在 ID 定义处
grep -qE 'af_trigger.*\(V4L2LOOPBACK_CID_BASE\+4 0x0098f004' $P/back_camera/scripts/patch_v4l2loopback_af.py && bad "patch 脚本 ID 定义仍为旧值" || ok "patch 脚本 ID 定义无旧值 (仅历史对照文字)"

echo "=== 3. 与运行模块实测一致 (base=0xf900) ==="
# 反汇编当前运行模块 (解压到文件后 objdump, 管道方式不可靠)
zstd -d -f /lib/modules/$(uname -r)/updates/dkms/v4l2loopback.ko.zst -o /tmp/v4l2loopback-verify.ko 2>/dev/null
objdump -d /tmp/v4l2loopback-verify.ko 2>/dev/null | grep -q '98f904' && ok "运行模块反汇编含 0x98f904 (base=f900)" || bad "运行模块无 0x98f904"
objdump -d /tmp/v4l2loopback-verify.ko 2>/dev/null | grep -q '98f004' && bad "运行模块含旧 0x98f004!" || ok "运行模块无旧 0x98f004"
rm -f /tmp/v4l2loopback-verify.ko
# 运行时控件 ID + 三方一致
ID=$(v4l2-ctl -d /dev/video16 --list-ctrls 2>/dev/null | grep af_trigger | awk '{print $2}' | tr -d '()')
[ "$ID" = "0x0098f904" ] && ok "运行时 af_trigger ID=$ID (0x0098f904)" || bad "运行时 af_trigger ID=$ID"
grep -q '0xf900' "$F1" && grep -q '0x0098f904' $P/back_camera/scripts/ov5670-router.c && ok "源码/脚本/router 三方一致 (f900/f904)" || bad "三方不一致"

echo "=== 4. git 已提交 ==="
git -C $P log --oneline -1 -- back_camera/patched-sources/v4l2loopback.c | grep -q '6e41c7d' && ok "base 统一提交 6e41c7d 存在" || bad "提交缺失"
git -C $P status --short back_camera/patched-sources/ back_camera/scripts/patch_v4l2loopback_af.py | grep -q . && bad "项目内改动未提交" || ok "项目内改动已全部提交 (工作区干净)"

echo "=== 5. unify 脚本正确性 (待 sudo 执行的 /usr/src 部分) ==="
[ -f /tmp/unify-v4l2loopback-base.sh ] && ok "unify 脚本就绪" || bad "unify 脚本缺失"
grep -q '0xf900' /tmp/unify-v4l2loopback-base.sh && ok "unify 脚本目标=0xf900" || bad "unify 脚本目标错误"
# /usr/src 现状 (sudo 未执行时应为 0xf000 — 预期待办)
SRC_BASE=$(grep -oP 'V4L2_CID_USER_BASE \| \K0x[0-9a-f]+' /usr/src/v4l2loopback-0.15.4/v4l2loopback.c 2>/dev/null | head -1)
echo "  (信息) /usr/src 当前 base=$SRC_BASE — sudo 同步后应为 0xf900"

echo ""
echo "════════ 结果 ════════"
echo "PASS=$PASS FAIL=$FAIL (ad-hoc 验证, 非套件)"
exit $FAIL
