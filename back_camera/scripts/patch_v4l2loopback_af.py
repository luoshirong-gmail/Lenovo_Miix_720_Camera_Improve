#!/usr/bin/env python3
"""patch_v4l2loopback_af.py — v4l2loopback 对焦控件补丁 (2026-08-08 全新重做)

在 v4l2loopback 上暴露标准对焦控件 (仅 card_label 含 "OV5670" 的设备):
  - focus_auto     (V4L2_CID_FOCUS_AUTO 0x009a090c, bool)  自动/手动
  - focus_absolute (V4L2_CID_FOCUS_ABSOLUTE 0x009a090a, int 0-1023) 手动
  - af_trigger     (V4L2LOOPBACK_CID_BASE+4 0x0098f904, int 0/1) 触发扫描
    ⚠️ 2026-08-09 (版本统一): 运行模块 base=0xf900 (无条件注册版实测),
    故 af_trigger 实际 ID=0x0098f904 (非 0x0098f004)。router.c 按此适配。

S_CTRL 值存储到设备变量, router 侧轮询 G_CTRL 感知变化 (三层链路:
V4L2 控件 → router 转发 → libcamerasrc → IPA)。

设计要点 (全新, 不重用旧脚本):
  - 幂等: 锚点含补丁标记, 已打则跳过
  - 仅 OV5670: handler_init 时检查 dev->card_label
  - 控件值存储: v4l2loopback_set_ctrl 的 switch 加 3 个 case
  - 并发安全: 值写入用 spin_lock (与 sustain_framerate 一致)

用法:
  python3 patch_v4l2loopback_af.py check|apply|revert
"""
import re
import sys

PATH = "/usr/src/v4l2loopback-0.15.4/v4l2loopback.c"
MARK = "ov5670-af-20260808"

# ---------- 补丁片段 ----------

CID_ADD = """
/* ⚠️ ov5670-af-20260808: 标准对焦控件 (仅 OV5670 设备暴露) */
#define CID_FOCUS_AUTO (V4L2_CID_FOCUS_AUTO)
#define CID_FOCUS_ABSOLUTE (V4L2_CID_FOCUS_ABSOLUTE)
#define CID_AF_TRIGGER (V4L2LOOPBACK_CID_BASE + 4)
"""

DEV_VAR_ADD = """
\tint focus_auto; /* ⚠️ ov5670-af-20260808: 对焦控件存储 */
\tint focus_absolute;
\tint af_trigger;"""

CTRL_ADD = """
/* ⚠️ ov5670-af-20260808: 对焦控件配置 */
static const struct v4l2_ctrl_config v4l2loopback_ctrl_focus_auto = {
\t// clang-format off
\t.ops\t= &v4l2loopback_ctrl_ops,
\t.id\t= CID_FOCUS_AUTO,
\t.name\t= "focus_auto",
\t.type\t= V4L2_CTRL_TYPE_BOOLEAN,
\t.min\t= 0,
\t.max\t= 1,
\t.step\t= 1,
\t.def\t= 1,
\t// clang-format on
};
static const struct v4l2_ctrl_config v4l2loopback_ctrl_focus_absolute = {
\t// clang-format off
\t.ops\t= &v4l2loopback_ctrl_ops,
\t.id\t= CID_FOCUS_ABSOLUTE,
\t.name\t= "focus_absolute",
\t.type\t= V4L2_CTRL_TYPE_INTEGER,
\t.min\t= 0,
\t.max\t= 1023,
\t.step\t= 1,
\t.def\t= 0,
\t// clang-format on
};
static const struct v4l2_ctrl_config v4l2loopback_ctrl_af_trigger = {
\t// clang-format off
\t.ops\t= &v4l2loopback_ctrl_ops,
\t.id\t= CID_AF_TRIGGER,
\t.name\t= "af_trigger",
\t.type\t= V4L2_CTRL_TYPE_INTEGER,
\t.min\t= 0,
\t.max\t= 1,
\t.step\t= 1,
\t.def\t= 0,
\t// clang-format on
};
"""

SCTRL_ADD = """
\tcase CID_FOCUS_AUTO:
\t\tif (val < 0 || val > 1)
\t\t\treturn -EINVAL;
\t\tspin_lock_bh(&dev->lock);
\t\tdev->focus_auto = val;
\t\tspin_unlock_bh(&dev->lock);
\t\tbreak;
\tcase CID_FOCUS_ABSOLUTE:
\t\tif (val < 0 || val > 1023)
\t\t\treturn -EINVAL;
\t\tspin_lock_bh(&dev->lock);
\t\tdev->focus_absolute = val;
\t\tspin_unlock_bh(&dev->lock);
\t\tbreak;
\tcase CID_AF_TRIGGER:
\t\tif (val < 0 || val > 1)
\t\t\treturn -EINVAL;
\t\tspin_lock_bh(&dev->lock);
\t\tdev->af_trigger = val;
\t\tspin_unlock_bh(&dev->lock);
\t\tbreak;
"""

# 注册 (handler_init, 仅 OV5670) — 在 timeoutimageio 注册后插入
REGISTER_OLD = "\tv4l2_ctrl_new_custom(hdl, &v4l2loopback_ctrl_timeoutimageio, NULL);"
REGISTER_NEW = """\tv4l2_ctrl_new_custom(hdl, &v4l2loopback_ctrl_timeoutimageio, NULL);
\t/* ⚠️ ov5670-af-20260808: 对焦控件 (仅 OV5670 card_label 设备暴露) */
\tif (dev->card_label[0] && strstr(dev->card_label, "OV5670")) {
\t\tv4l2_ctrl_new_custom(hdl, &v4l2loopback_ctrl_focus_auto, NULL);
\t\tv4l2_ctrl_new_custom(hdl, &v4l2loopback_ctrl_focus_absolute, NULL);
\t\tv4l2_ctrl_new_custom(hdl, &v4l2loopback_ctrl_af_trigger, NULL);
\t}"""

# ---------- 锚点检查 ----------
def load():
    with open(PATH) as f:
        return f.read()

def save(src):
    with open(PATH, "w") as f:
        f.write(src)

def is_applied(src):
    return MARK in src and "CID_FOCUS_AUTO" in src

def check():
    src = load()
    if is_applied(src):
        print("✅ 补丁已应用 (幂等跳过)")
        return 0
    print("❌ 补丁未应用")
    return 1

def apply():
    src = load()
    if is_applied(src):
        print("✅ 补丁已应用 (幂等跳过)")
        return 0
    orig = src

    # ① CID 定义 (CID_TIMEOUT_IMAGE_IO 之后)
    anchor1 = "#define CID_TIMEOUT_IMAGE_IO (V4L2LOOPBACK_CID_BASE + 3)"
    assert anchor1 in src, "锚点1 (CID 定义) 未找到"
    src = src.replace(anchor1, anchor1 + CID_ADD, 1)

    # ② 设备变量 (keep_format 之后)
    anchor2 = "\tint keep_format;"
    assert anchor2 in src, "锚点2 (设备变量) 未找到"
    src = src.replace(anchor2, anchor2 + DEV_VAR_ADD, 1)

    # ③ 控件配置 (timeoutimageio 配置之后)
    anchor3 = "static const struct v4l2_ctrl_config v4l2loopback_ctrl_timeoutimageio = {"
    idx3 = src.find(anchor3)
    assert idx3 >= 0, "锚点3 (控件配置) 未找到"
    end3 = src.find("};", idx3)
    assert end3 >= 0, "锚点3 结束未找到"
    src = src[:end3 + 2] + CTRL_ADD + src[end3 + 2:]

    # ④ s_ctrl 存储 (CID_TIMEOUT_IMAGE_IO case 之后)
    anchor4 = "\tcase CID_TIMEOUT_IMAGE_IO:"
    idx4 = src.find(anchor4)
    assert idx4 >= 0, "锚点4 (s_ctrl case) 未找到"
    # 找到该 case 的 break;
    end4 = src.find("\t\tbreak;", idx4)
    assert end4 >= 0, "锚点4 break 未找到"
    src = src[:end4 + len("\t\tbreak;")] + SCTRL_ADD + src[end4 + len("\t\tbreak;"):]

    # ⑤ 注册 (handler_init, 仅 OV5670)
    assert REGISTER_OLD in src, "锚点5 (注册) 未找到"
    src = src.replace(REGISTER_OLD, REGISTER_NEW, 1)

    assert MARK in src, "补丁标记未写入"
    save(src)
    print("✅ v4l2loopback 对焦控件补丁已应用")
    return 0

def revert():
    src = load()
    if not is_applied(src):
        print("✅ 未应用, 无需回滚")
        return 0
    # 反向: 移除补丁片段 (按注册→s_ctrl→配置→变量→CID 顺序反向)
    src = src.replace(REGISTER_NEW, REGISTER_OLD, 1)
    for frag in (SCTRL_ADD, CTRL_ADD, DEV_VAR_ADD, CID_ADD):
        assert frag in src, f"回滚: 片段缺失 {frag[:40]}"
        src = src.replace(frag, "", 1)
    save(src)
    print("✅ v4l2loopback 对焦控件补丁已回滚")
    return 0

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "check"
    rc = {"check": check, "apply": apply, "revert": revert}[cmd]()
    sys.exit(rc)
