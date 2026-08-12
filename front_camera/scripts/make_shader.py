#!/usr/bin/env python3
"""Prepare the GLSL shader for GStreamer CLI injection.

GStreamer's pipeline string parser is whitespace/`#`-sensitive:
- Real newlines split tokens (multi-line attribute values break parsing)
- '#' starts a comment in pipeline syntax
- '//' line comments would swallow the rest of a single-line shader

So this script produces a single-line GLSL source with:
  * no '#version' / '#define' directives (GStreamer injects its own #version)
  * no '//' line comments
  * IN_WIDTH / IN_HEIGHT const declarations updated with runtime values
"""
import sys
import re


def main():
    # ⚠️ 2026-08-10 (参数化): 支持 --set NAME=VALUE (可多个, 覆盖模板常量)
    # 前摄调用不变 (无 --set 用模板默认); 后摄 router 传配置参数
    # ⚠️ 2026-08-11 (行 FPN 机制): --fpn-file=path 注入行偏移表
    overrides = {}
    fpn_file = None
    args = sys.argv[1:]
    rest = []
    i = 0
    while i < len(args):
        if args[i] == '--set' and i + 1 < len(args):
            kv = args[i + 1]
            if '=' in kv:
                n, v = kv.split('=', 1)
                overrides[n] = v
                i += 2
                continue
        if args[i].startswith('--fpn-file='):
            fpn_file = args[i].split('=', 1)[1]
            i += 1
            continue
        rest.append(args[i])
        i += 1

    if len(rest) < 4:
        print("Usage: make_shader.py template.frag out.frag in_width in_height"
              " [--set NAME=VALUE ...] [--fpn-file=path]", file=sys.stderr)
        sys.exit(1)

    template = rest[0]
    output = rest[1]
    in_w = float(rest[2])
    in_h = float(rest[3])

    with open(template, 'r') as f:
        lines = f.readlines()

    clean_lines = []
    for line in lines:
        stripped = line.strip()
        # Convert #define NAME value -> const float NAME = value;
        # (GStreamer CLI cannot pass '#' directives in attribute values)
        if stripped.startswith('#define '):
            rest = stripped[len('#define '):]
            # Cut trailing // comment before parsing value
            cidx = rest.find('//')
            if cidx != -1:
                rest = rest[:cidx]
            parts = rest.split(None, 1)
            if len(parts) == 2 and parts[0] not in ('IN_WIDTH', 'IN_HEIGHT'):
                name, value = parts[0], parts[1].rstrip(';').strip()
                if value.replace('.', '').isdigit() or value.startswith('-'):
                    clean_lines.append(f'const float {name} = {value};')
                continue
            else:
                # IN_WIDTH / IN_HEIGHT handled below
                continue
        # Drop other preprocessor directives (#version etc.)
        if stripped.startswith('#'):
            continue
        # Update const float IN_WIDTH/IN_HEIGHT declarations with runtime values
        m = re.match(r'const\s+float\s+(IN_WIDTH|IN_HEIGHT)\s*=\s*[0-9.]+;', stripped)
        if m:
            name = m.group(1)
            value = f'{in_w:.1f}' if name == 'IN_WIDTH' else f'{in_h:.1f}'
            clean_lines.append(f'const float {name} = {value};')
            continue
        # ⚠️ 2026-08-10 (参数化): --set NAME=VALUE 覆盖模板常量
        m = re.match(r'const\s+float\s+([A-Z_]+)\s*=\s*[0-9.]+;', stripped)
        if m and m.group(1) in overrides:
            clean_lines.append(f'const float {m.group(1)} = {overrides[m.group(1)]};')
            continue
        # Cut // line comments (block comments /* */ are fine single-line)
        idx = line.find('//')
        if idx != -1:
            line = line[:idx]
        clean_lines.append(line)

    source = '\n'.join(clean_lines)

    # ⚠️ 2026-08-11 (行 FPN 机制): 注入行偏移表 (每行一个 float)
    # GLSL ES 1.0 无数组初始化 → 段化 if-else 查表函数 (每 ROW_FPN_STEP 行一段)
    if fpn_file:
        try:
            with open(fpn_file, 'r') as f:
                vals = [float(x.strip()) for x in f if x.strip()]
        except (OSError, ValueError) as e:
            print(f"make_shader: --fpn-file 读取失败: {e}", file=sys.stderr)
            sys.exit(1)
        if len(vals) != int(in_h):
            print(f"make_shader: FPN 表行数 {len(vals)} != IN_HEIGHT {int(in_h)}",
                  file=sys.stderr)
            sys.exit(1)
        step = 4  # 段宽 (行) — 与模板 ROW_FPN_STEP 一致
        import math
        nseg = math.ceil(len(vals) / step)
        parts = []
        for i in range(nseg):
            seg = vals[i * step:(i + 1) * step]
            v = sum(seg) / len(seg)
            r1 = min((i + 1) * step, len(vals)) - 1
            if i == nseg - 1:
                parts.append(f"return {v:.4f};")
            else:
                parts.append(f"if(row<{r1 + 1})return {v:.4f};")
        func = "float row_fpn(int row){" + "".join(parts) + "}"
        # 替换模板占位: float row_fpn(int row) { return 0.0; }
        m = re.search(r'float row_fpn\(int row\)\s*\{[^}]*\}', source)
        if not m:
            print("make_shader: 模板缺 row_fpn 占位函数", file=sys.stderr)
            sys.exit(1)
        source = source[:m.start()] + func + source[m.end():]
        # 启用开关 (模板 ROW_FPN_EN 常量被覆盖)
        m2 = re.search(r'const float ROW_FPN_EN = [0-9.]+;', source)
        if m2:
            source = source[:m2.start()] + 'const float ROW_FPN_EN = 1.0;' + source[m2.end():]
        print(f"make_shader: 行 FPN 注入 {len(vals)} 值 → {nseg} 段 (step={step}), EN=1",
              file=sys.stderr)

    # Collapse to one line (GLSL is whitespace-insensitive otherwise)
    source = ' '.join(source.split())

    with open(output, 'w') as f:
        f.write(source)


if __name__ == '__main__':
    main()
