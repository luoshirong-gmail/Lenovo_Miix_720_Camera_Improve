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
    if len(sys.argv) < 5:
        print("Usage: make_shader.py template.frag out.frag in_width in_height",
              file=sys.stderr)
        sys.exit(1)

    template = sys.argv[1]
    output = sys.argv[2]
    in_w = float(sys.argv[3])
    in_h = float(sys.argv[4])

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
        # Cut // line comments (block comments /* */ are fine single-line)
        idx = line.find('//')
        if idx != -1:
            line = line[:idx]
        clean_lines.append(line)

    source = '\n'.join(clean_lines)

    # Collapse to one line (GLSL is whitespace-insensitive otherwise)
    source = ' '.join(source.split())

    with open(output, 'w') as f:
        f.write(source)


if __name__ == '__main__':
    main()
