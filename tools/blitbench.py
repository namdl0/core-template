#!/usr/bin/env python3
"""Turn a blitgen output dir (mem.bin, cmds.hex, expect.hex, args.txt) into SDRAM preload files
for the SoC blitter benchmark (firmware/bench, sim/verilator/tb_soc.cpp +preload=).
  tools/blitbench.py <blitgen dir> <out dir>   -> mem.le, hdr.le, expect.le, preload.txt"""
import os, struct, sys
src, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
raw = open(os.path.join(src, 'mem.bin'), 'rb').read()               # big-endian words ($fread)
le = b''.join(raw[i:i + 4][::-1] for i in range(0, len(raw), 4))
open(os.path.join(out, 'mem.le'), 'wb').write(le)
words = [int(l, 16) for l in open(os.path.join(src, 'cmds.hex')) if l.strip()]
n, cmds = words[0], words[1:]
args = dict(a.lstrip('+').split('=') for a in open(os.path.join(src, 'args.txt')).read().split())
dbase, dwords = int(args['dbase'], 16), int(args['dwords'], 16)
hdr = struct.pack('<4I', 0x484E4342, n, dbase, dwords) + b'\0' * (256 - 16) + struct.pack('<%dI' % n, *cmds[:n])
open(os.path.join(out, 'hdr.le'), 'wb').write(hdr)
exp = [int(l, 16) for l in open(os.path.join(src, 'expect.hex')) if l.strip()]
open(os.path.join(out, 'expect.le'), 'wb').write(struct.pack('<%dI' % len(exp), *exp))
assert len(exp) == dwords, (len(exp), dwords)
print(f"+preload={out}/mem.le@0 +preload={out}/hdr.le@1000000 +preload={out}/expect.le@1800000")
open(os.path.join(out, 'preload.txt'), 'w').write(
    f"+preload={out}/mem.le@0 +preload={out}/hdr.le@1000000 +preload={out}/expect.le@1800000\n")
print(f"{n // 8} commands, image {len(le) >> 10} KB, check region {dwords} words at word {dbase:#x}")
