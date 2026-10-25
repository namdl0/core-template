#!/usr/bin/env python3
"""bin2hex.py - split a firmware binary into 4 byte-lane $readmemh files for the boot RAM.

usage: bin2hex.py <in.bin> <out_prefix> <ram_bytes>
writes <out_prefix>_b0.hex .. _b3.hex (one hex byte per line, ram_bytes/4 lines each).
Lane k holds byte k of every little-endian 32-bit word (ufo50_soc.v bram0..bram3).
"""
import os
import sys

def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    data = open(sys.argv[1], "rb").read()
    size = int(sys.argv[3], 0)
    if len(data) > size:
        sys.exit("firmware is %d bytes, boot RAM is %d" % (len(data), size))
    data = data + bytes(size - len(data))
    os.makedirs(os.path.dirname(sys.argv[2]) or ".", exist_ok=True)
    for lane in range(4):
        with open("%s_b%d.hex" % (sys.argv[2], lane), "w", newline="\n") as f:
            f.write("".join("%02x\n" % b for b in data[lane::4]))
    print("%s_b[0-3].hex: %d bytes used of %d" % (sys.argv[2], len(data.rstrip(b"\0")), size))

if __name__ == "__main__":
    main()
