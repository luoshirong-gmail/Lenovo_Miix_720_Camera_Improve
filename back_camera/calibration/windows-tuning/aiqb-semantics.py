#!/usr/bin/env python3
"""AIQB cpf 记录语义分析 — 尺寸关系推断各记录内容"""
import struct
DATA = open('OV5670_CJAG514_SKY.cpf','rb').read()
off = 0x18
n = 0
print(f"{'rec':>3} {'off':>7} {'size':>8} {'tag':>5}  可能内容")
while off + 8 < len(DATA):
    rsz = struct.unpack_from('<I', DATA, off)[0]
    tag = struct.unpack_from('<H', DATA, off+6)[0]
    d = DATA[off+8:off+rsz]
    hint = ''
    if tag == 1: hint = '名称/版本字符串'
    elif tag == 2: hint = 'sensor 分辨率 (2592x1944)'
    elif tag == 3: hint = 'sensor 特性/色温增益基础 (256B)'
    elif tag == 5: hint = '16B 小参数'
    elif tag == 13: hint = '80B 参数 (含分辨率)'
    elif tag == 7: hint = '16B'
    elif tag == 10:
        # 网格分析
        w, h = struct.unpack_from('<HH', d, 2)
        hint = f'LSC 表? 网格 {w}x{h} (41x31=1271) 61KB'
    elif tag == 15: hint = '680B'
    elif tag == 17: hint = '16B'
    elif tag == 18: hint = '520B'
    elif tag == 19: hint = '48B'
    elif tag == 20: hint = '24B'
    elif tag == 258:
        u16n = len(d)//2
        hint = f'u16 表 {u16n} 值 — 43x36x4={43*36*4}? {u16n==43*36*4-12}'
    elif tag == 513:
        u16n = len(d)//2
        hint = f'大表 {u16n} u16 — {u16n/4:.0f}x4 或网格?'
    print(f"{n:>3} {off:>7} {rsz:>8} {tag:>5}  {hint}")
    off += rsz
    n += 1
