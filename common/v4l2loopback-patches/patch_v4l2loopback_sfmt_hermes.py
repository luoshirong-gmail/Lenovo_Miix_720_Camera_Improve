#!/usr/bin/env python3
"""Patch v4l2loopback vidioc_s_fmt_vid (HERMES-PATCH):
CAPTURE readers may reuse the writer's format.

Problem: with an active writer (camera-router resident writer), the
CAPTURE stream token is held -> a reader's S_FMT(CAPTURE) request hits
`if (!(dev->format_tokens & token)) return -EBUSY` -> the reader cannot
open the device (system camera shows "could not play camera stream").

Fix: when a CAPTURE S_FMT arrives and another owner (the writer) is
active, accept it by substituting the device's current format and
granting the reader the CAPTURE token.

This is REQUIRED for the "resident writer + concurrent reader"
architecture (camera-router). Together with D-1 v4 (enum_fmt), it lets
PipeWire/spa-v4l2 open and negotiate the loopback device while the
writer is streaming.

Relevant source (v4l2loopback.c, vidioc_s_fmt_vid):
  if (opener->format_token)
      release_token(dev, opener, format);
  [INSERT HERE]
  if (!(dev->format_tokens & token)) {
      result = -EBUSY;
      goto exit_s_fmt_unlock;
  }
"""
import re

SRC = "/usr/src/v4l2loopback-0.15.4/v4l2loopback.c"

with open(SRC) as f:
    src = f.read()

anchor = """\tif (opener->format_token)
\t\trelease_token(dev, opener, format);
\tif (!(dev->format_tokens & token)) {
\t\tresult = -EBUSY;
\t\tgoto exit_s_fmt_unlock;
\t}"""

patched = """\tif (opener->format_token)
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

if "HERMES-PATCH" in src:
    print("HERMES-PATCH already applied — no change")
elif anchor in src:
    src = src.replace(anchor, patched, 1)
    with open(SRC, "w") as f:
        f.write(src)
    print("HERMES-PATCH APPLIED: CAPTURE S_FMT reuses writer format")
else:
    print("ERROR: anchor not found — check current source state")
    raise SystemExit(1)
