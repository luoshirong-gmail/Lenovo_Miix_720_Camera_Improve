#!/usr/bin/env python3
"""
apply_all.py — v4l2loopback 统一补丁链 (Lenovo_Miix_720_Camera_Improve 合并版)

合并自 4 个历史脚本 (2026-08-08, 合并项目 P3):
  - patch_v4l2loopback_enumfmt_fixed.py   → ① D-1 v4  (enum_fmt)
  - patch_v4l2loopback_sfmt_hermes.py     → ② HERMES-PATCH (s_fmt)
  - kpatch_v4l2loopback_min3.py           → ③ MIN-3 ④ IMAGE-ON-DEMAND (reqbufs)

补丁顺序固化 (区域互不重叠, 但保持历史应用顺序):
  ① D-1 v4 → ② HERMES-PATCH → ③ MIN-3 → ④ IMAGE-ON-DEMAND

每个补丁幂等: 以源码中的特征注释标记检测, 已应用则跳过。

为什么需要这 4 个补丁 (功能层, 非硬件驱动):
  - D-1 v4: 有 writer 缓冲 (dev->image) 时 ENUM_FMT 只列当前格式 (NV12),
    否则 exclusive_caps=0 时 spa-v4l2 枚举 RGB 表 → PipeWire 协商 EINVAL (-22)
  - HERMES-PATCH: writer 活跃时 CAPTURE reader 的 S_FMT 复用 writer 格式,
    否则 reader 拿不到 CAPTURE token → EBUSY → 系统相机打不开
  - MIN-3: writer REQBUFS 提升到最少 3 个 buffer (PipeWire/spa-v4l2 下限),
    否则 idle 5fps 池缩到 2 → "can't allocate enough buffers 2 < 3"
    ⚠️ 只提升 writer: reader 拿 > writer 数量会 SEGV (v4l2loopback 共享缓冲越界)
  - IMAGE-ON-DEMAND: REQBUFS 分配条件放宽到 !dev->image, 修复 wireplumber
    开机探测与 router 启动的竞态 (否则 dev->image 永久 NULL → D-1 失效)

用法:
  # 检查补丁状态 (只读, 不修改)
  python3 apply_all.py --check [<v4l2loopback.c>]
  # 应用全部缺失补丁
  sudo python3 apply_all.py [<v4l2loopback.c>]     # 默认 /usr/src/v4l2loopback-0.15.4/v4l2loopback.c

打补丁后 (需要 root, 见 docs/UPGRADE.md 完整流程):
  cd /usr/src/v4l2loopback-0.15.4
  sudo make -C /lib/modules/$(uname -r)/build M=$PWD
  sudo kmodsign sha512 /usr/local/share/mok/MOK.key /usr/local/share/mok/MOK.der v4l2loopback.ko
  sudo rm -f /lib/modules/$(uname -r)/updates/dkms/v4l2loopback.ko.zst
  sudo cp v4l2loopback.ko /lib/modules/$(uname -r)/updates/dkms/
  sudo depmod -a && sudo modprobe -r v4l2loopback && sudo modprobe v4l2loopback
  (重载后: v4l2loopback-ctl add 重建 video16 + 重启两个服务 + 重启 wireplumber)
"""
import sys

DEFAULT_SRC = "/usr/src/v4l2loopback-0.15.4/v4l2loopback.c"

# ---------------------------------------------------------------- ① D-1 v4
# ⚠️ 官方 0.15.4 的 fixed 行就是 "keep_format || has_other_owners" 单行
#    (旧脚本的 old 文本含 announce_all_caps, 是针对 0.15.3/更早版本写的 —
#     对官方 0.15.4 不匹配。此处以官方 0.15.4 tar 源码为准核对)
D1_MARK = "D-1 patch"
D1_OLD = """\tint fixed = dev->keep_format || has_other_owners(opener, dev);"""
D1_NEW = """\tint fixed = dev->keep_format || has_other_owners(opener, dev) ||
\t\t    dev->image != NULL;
\t/* D-1 patch (v4): enumerate only the current format when a writer has
\t * allocated buffers (dev->image set), regardless of announce_all_caps.
\t * v3 used has_other_owners which also gates S_FMT/REQBUFS token logic
\t * -> broke reader STREAMON (EIO). dev->image is the buffer-allocation
\t * signal, orthogonal to opener tokens, so readers stay unaffected.
\t * Without this, exclusive_caps=0 makes spa-v4l2 enumerate the RGB
\t * table (BGR4/RGB4/...) while the writer is NV12 -> PipeWire link
\t * error EINVAL (-22). */"""

# ------------------------------------------------------- ② HERMES-PATCH
# ⚠️ 官方 0.15.4 中 release_token 前是 2 个 tab (对齐缩进), 旧脚本写 1 个
#    tab 导致在官方源码上不匹配 — 以官方 tar cat -A 实测为准
HERMES_MARK = "HERMES-PATCH"
HERMES_OLD = """\tif (opener->format_token)
\t\trelease_token(dev, opener, format);
\tif (!(dev->format_tokens & token)) {
\t\tresult = -EBUSY;
\t\tgoto exit_s_fmt_unlock;
\t}"""
HERMES_NEW = """\tif (opener->format_token)
\t\trelease_token(dev, opener, format);
\t/* HERMES-PATCH: CAPTURE readers may reuse the writer's format. */
\t/* With a writer active the CAPTURE token is absent -> EBUSY -> */
\t/* PipeWire silently drops frames (2nd-open stutter). Accept */
\t/* S_FMT by substituting the device format and granting the token. */
\tif (V4L2_TYPE_IS_CAPTURE(f->type) &&
\t    has_other_owners(opener, dev)) {
\t\tf->fmt.pix = dev->pix_format;
\t\tacquire_token(dev, opener, format, token);
\t\tgoto exit_s_fmt_unlock;
\t}
\tif (!(dev->format_tokens & token)) {
\t\tresult = -EBUSY;
\t\tgoto exit_s_fmt_unlock;
\t}"""

# ------------------------------------------------------------- ③ MIN-3
MIN3_MARK = "MIN-3 patch"
MIN3_OLD = """\tif (has_other_owners(opener, dev) && dev->used_buffer_count > 0) {
\t\t/* allow 'allocation' of existing number of buffers */
\t\treq_count = dev->used_buffer_count;
\t} else if (any_mapped_buffer(dev)) {"""
MIN3_NEW = """\t/* MIN-3 patch: enforce minimum buffer allocation of 3.
\t * v4l2sink with a 5fps appsrc source requests only 2 (pool follows
\t * actual stream rate despite caps declaring 29/1); PipeWire/spa-v4l2
\t * requires >= 3 -> 'can't allocate enough buffers 2 < 3' on re-open.
\t * Only the writer is raised (to 3); readers then get used=3 too, so
\t * no reader ever maps more buffers than the writer (avoids the SEGV
\t * seen when readers were allowed to exceed the writer's count). */
\tif (req_count < 3 && !has_other_owners(opener, dev))
\t\treq_count = 3;
""" + MIN3_OLD

# -------------------------------------------------- ④ IMAGE-ON-DEMAND
IOD_MARK = "IMAGE-ON-DEMAND patch"
IOD_OLD = """\tif (has_no_owners(dev)) {
\t\tresult = allocate_buffers(dev, &dev->pix_format);
\t\tif (result < 0)
\t\t\tgoto exit_reqbufs_unlock;
\t}"""
IOD_NEW = """\t/* IMAGE-ON-DEMAND patch: allocate when the device has no image yet, even
\t * if another opener (e.g. wireplumber probe) holds a format token.
\t * Otherwise dev->image stays NULL forever -> D-1 ENUM_FMT patch inactive
\t * -> full RGB table enumerated -> PipeWire apps fail -22 EINVAL. */
\tif (has_no_owners(dev) || !dev->image) {
\t\tresult = allocate_buffers(dev, &dev->pix_format);
\t\tif (result < 0)
\t\t\tgoto exit_reqbufs_unlock;
\t}"""

# 顺序固化: (名称, 标记, old, new)
PATCHES = [
    ("D-1 v4 (enum_fmt)",          D1_MARK,     D1_OLD,     D1_NEW),
    ("HERMES-PATCH (s_fmt)",       HERMES_MARK, HERMES_OLD, HERMES_NEW),
    ("MIN-3 (reqbufs)",            MIN3_MARK,   MIN3_OLD,   MIN3_NEW),
    ("IMAGE-ON-DEMAND (reqbufs)",  IOD_MARK,    IOD_OLD,    IOD_NEW),
]


def main(path, check_only):
    with open(path) as f:
        src = f.read()

    print(f"补丁链检查: {path}")
    all_ok = True
    for name, mark, old, new in PATCHES:
        applied = mark in src
        target_ok = old in src
        status = "✅ 已应用" if applied else ("❌ 缺失" if target_ok else "❌ 目标代码未找到(版本不符?)")
        print(f"  {name:26s} → {status}")
        if not applied:
            all_ok = False
            if not target_ok:
                print(f"      ⚠️ 无法应用: 目标代码块不匹配 — 检查 v4l2loopback 版本 (需要 0.15.4)")
    if all_ok:
        print("全部补丁在位 ✅ (无操作)")
        return 0

    if check_only:
        print("--check 模式: 仅报告, 未修改任何文件")
        return 1

    # 逐补丁应用 (缺失才打)
    for name, mark, old, new in PATCHES:
        if mark in src:
            continue
        if old not in src:
            print(f"❌ 跳过 {name}: 目标代码块未找到")
            continue
        src = src.replace(old, new, 1)
        print(f"✅ 应用 {name}")
    with open(path, 'w') as f:
        f.write(src)
    print("补丁链应用完成 (重新编译/签名/安装见 docs/UPGRADE.md)")
    return 0


if __name__ == '__main__':
    args = sys.argv[1:]
    check_only = False
    if args and args[0] == '--check':
        check_only = True
        args = args[1:]
    path = args[0] if args else DEFAULT_SRC
    sys.exit(main(path, check_only))
