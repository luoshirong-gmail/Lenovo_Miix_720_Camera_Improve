#!/usr/bin/env python3
"""REVERT D-1 v3 patch: restore original enum_fmt fixed logic.
Used to isolate whether D-1 v3 causes the reader STREAMON EIO.
"""
import re

SRC = "/usr/src/v4l2loopback-0.15.4/v4l2loopback.c"

with open(SRC) as f:
    src = f.read()

# Current (D-1 v3)
old = """\tint fixed = dev->keep_format || has_other_owners(opener, dev);
\t/* D-1 patch (v3): when an active writer (other owner) holds the device,
\t * enumerate ONLY that writer's format regardless of announce_all_caps.
\t * v2 used pix_format!=0 which is wrong: pix_format defaults to BGR4 at
\t * module load, so the enum was always fixed to BGR4 and v4l2sink's NV12
\t * negotiation failed EINVAL. has_other_owners is the correct "writer
\t * active" signal. Without this, exclusive_caps=0 makes spa-v4l2 see the
\t * RGB table and negotiate a format that never matches the NV12 writer. */"""

# Original (before any D-1)
new = """\tint fixed = !dev->announce_all_caps &&
\t\t    (dev->keep_format || has_other_owners(opener, dev));  /* C-3 patch: full enum when announce_all_caps */"""

if old in src:
    src = src.replace(old, new, 1)
    with open(SRC, "w") as f:
        f.write(src)
    print("D-1 v3 REVERTED (back to C-3 original)")
else:
    print("ERROR: D-1 v3 block not found")
    raise SystemExit(1)
