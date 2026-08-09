#!/usr/bin/env python3
# kpatch_v4l2loopback_min3.py — v4l2loopback 补丁包 (正式版, 2026-08-06 验证)
#
# 包含两个补丁 (均已实测验证):
#
# ① MIN-3: OV5670 router 的 idle 链用 appsrc 声明 29/1 caps 但实际推 5fps。
#   v4l2sink 的 buffer pool 按"实际流速率"缩到 2 (即使 caps 声明 29/1)
#   → PipeWire/spa-v4l2 要 3 个 buffer → "can't allocate enough buffers 2 < 3"
#   → 相机第二次打不开。REQBUFS 时把 writer 的请求提升到最少 3 个 buffer。
#   ⚠️ 只提升 writer (!has_other_owners): reader 维持 used=writer 数量。
#   ⚠️ 危险: 若允许 reader 请求 > writer 数量 → PipeWire SEGV (core-dump,
#     共享 buffer 越界); "reader 不重置队列" 也会 index 映射错乱 SEGV。
#   验证: reader REQBUFS(3)→3, 连续开关稳定, PipeWire 0 崩溃, idle CPU 0%。
#
# ② IMAGE-ON-DEMAND: REQBUFS 分配条件 has_no_owners → has_no_owners || !dev->image。
#   背景: wireplumber 探测 (CAPTURE opener) 先于 router 的 v4l2sink REQBUFS 时,
#   has_no_owners=false → allocate_buffers 不执行 → dev->image 永久 NULL →
#   D-1 ENUM_FMT 补丁 (dev->image != NULL gate) 失效 → 枚举全 RGB 表 →
#   PipeWire 应用 "wanted XR24 16x16, got NV12" → set output format -22 EINVAL
#   → 相机打不开 (重启后必现: wireplumber 开机探测 vs router 启动竞态)。
#   image 空时总是分配 → dev->image 设置 → D-1 生效 (ENUM_FMT 只列 NV12)。
#   验证: 设备侧 ENUM_FMT 只 NV12, 节点 EnumFormat NV12, 3/3 开关 96/100 真实帧。
#
# 用法 (内核更新后补丁丢失时):
#   sudo python3 kpatch_v4l2loopback_min3.py /usr/src/v4l2loopback-0.15.4/v4l2loopback.c
# 然后: cd /usr/src/v4l2loopback-0.15.4 && sudo make -C /lib/modules/$(uname -r)/build M=$PWD
#       sudo kmodsign sha512 /usr/local/share/mok/MOK.key /usr/local/share/mok/MOK.der v4l2loopback.ko
#       sudo rm -f /lib/modules/$(uname -r)/updates/dkms/v4l2loopback.ko.zst
#       sudo cp v4l2loopback.ko /lib/modules/$(uname -r)/updates/dkms/
#       sudo depmod -a && sudo modprobe -r v4l2loopback && sudo modprobe v4l2loopback
#       (重载后: v4l2loopback-ctl add 重建 video98 + 重启两个服务 + 重启 wireplumber)

import sys

PATCH = """\t/* MIN-3 patch: enforce minimum buffer allocation of 3.
\t * v4l2sink with a 5fps appsrc source requests only 2 (pool follows
\t * actual stream rate despite caps declaring 29/1); PipeWire/spa-v4l2
\t * requires >= 3 -> 'can't allocate enough buffers 2 < 3' on re-open.
\t * Only the writer is raised (to 3); readers then get used=3 too, so
\t * no reader ever maps more buffers than the writer (avoids the SEGV
\t * seen when readers were allowed to exceed the writer's count). */
\tif (req_count < 3 && !has_other_owners(opener, dev))
\t\treq_count = 3;

"""

TARGET = """\tif (has_other_owners(opener, dev) && dev->used_buffer_count > 0) {
\t\t/* allow 'allocation' of existing number of buffers */
\t\treq_count = dev->used_buffer_count;
\t} else if (any_mapped_buffer(dev)) {"""

PATCH2 = """\t/* IMAGE-ON-DEMAND patch: allocate when the device has no image yet, even
\t * if another opener (e.g. wireplumber probe) holds a format token.
\t * Otherwise dev->image stays NULL forever -> D-1 ENUM_FMT patch inactive
\t * -> full RGB table enumerated -> PipeWire apps fail -22 EINVAL. */
\tif (has_no_owners(dev) || !dev->image) {
\t\tresult = allocate_buffers(dev, &dev->pix_format);
\t\tif (result < 0)
\t\t\tgoto exit_reqbufs_unlock;
\t}"""

TARGET2 = """\tif (has_no_owners(dev)) {
\t\tresult = allocate_buffers(dev, &dev->pix_format);
\t\tif (result < 0)
\t\t\tgoto exit_reqbufs_unlock;
\t}"""


def main(path):
    with open(path) as f:
        src = f.read()

    applied = []
    if "MIN-3 patch" not in src:
        if TARGET not in src:
            print("❌ MIN-3 目标代码未找到 — 检查 v4l2loopback 版本 (需要 0.15.4) 或源码状态")
            return 1
        src = src.replace(TARGET, PATCH + TARGET, 1)
        applied.append("MIN-3")

    if "IMAGE-ON-DEMAND patch" not in src:
        if TARGET2 not in src:
            print("❌ IMAGE-ON-DEMAND 目标代码未找到 — 检查源码状态")
            return 1
        src = src.replace(TARGET2, PATCH2, 1)
        applied.append("IMAGE-ON-DEMAND")

    if applied:
        with open(path, 'w') as f:
            f.write(src)
        print(f"✅ 补丁已应用: {', '.join(applied)} (srcversion 将变为 965BFF8F 系列)")
        print("   下一步: make → kmodsign → 安装 (见脚本头部注释)")
    else:
        print("✅ 补丁已应用, 无需重复打")
    return 0


if __name__ == '__main__':
    if len(sys.argv) != 2:
        print("用法: sudo python3 %s <v4l2loopback.c>" % sys.argv[0])
        sys.exit(1)
    sys.exit(main(sys.argv[1]))
