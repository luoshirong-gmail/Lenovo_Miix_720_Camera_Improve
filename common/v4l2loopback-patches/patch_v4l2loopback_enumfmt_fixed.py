#!/usr/bin/env python3
"""Patch v4l2loopback vidioc_enum_fmt_vid (D-1 fix v4):
When the device has an active writer buffer (`dev->image != NULL` — a
writer did REQBUFS+S_FMT, so a real format exists), enumerate ONLY that
format regardless of announce_all_caps / exclusive_caps.

Why NOT has_other_owners / pix_format:
- v3 used has_other_owners -> broke reader STREAMON/REQBUFS (the same
  token check drives S_FMT and REQBUFS paths -> EIO on read)
- v2 used pix_format != 0 -> always true (defaults to BGR4 at load) ->
  v4l2sink NV12 negotiation failed

`dev->image` is set only when a writer allocated buffers (vidioc_reqbufs
with count>0 as OUTPUT owner). It's orthogonal to the opener token logic,
so readers are unaffected. Without this, exclusive_caps=0 lets spa-v4l2
enumerate the RGB table (BGR4/RGB4/...) while the actual writer is NV12 ->
PipeWire negotiates a nonexistent format -> link error EINVAL (-22).
"""
import re

SRC = "/usr/src/v4l2loopback-0.15.4/v4l2loopback.c"

with open(SRC) as f:
    src = f.read()

old = """\tint fixed = !dev->announce_all_caps &&
\t\t    (dev->keep_format || has_other_owners(opener, dev));  /* C-3 patch: full enum when announce_all_caps */"""

new = """\tint fixed = dev->keep_format || has_other_owners(opener, dev) ||
\t\t    dev->image != NULL;
\t/* D-1 patch (v4): enumerate only the current format when a writer has
\t * allocated buffers (dev->image set), regardless of announce_all_caps.
\t * v3 used has_other_owners which also gates S_FMT/REQBUFS token logic
\t * -> broke reader STREAMON (EIO). dev->image is the buffer-allocation
\t * signal, orthogonal to opener tokens, so readers stay unaffected.
\t * Without this, exclusive_caps=0 makes spa-v4l2 enumerate the RGB
\t * table (BGR4/RGB4/...) while the writer is NV12 -> PipeWire link
\t * error EINVAL (-22). */"""

if old in src:
    src = src.replace(old, new, 1)
    with open(SRC, "w") as f:
        f.write(src)
    print("PATCH D-1 v4 APPLIED: enum fixed to current format when writer buffers exist (dev->image)")
else:
    print("ERROR: target not found — check current source state")
    raise SystemExit(1)
