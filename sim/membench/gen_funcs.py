#!/usr/bin/env python3
"""gen_funcs.py N OUT.c - N leaf functions for the memory benchmark (membench.c): straight-line integer
code like cachebench's, plus an interpreter-like share of memory traffic: loads from a 48 KiB table and
stores to a small "operand stack" (about 1 store per 6 instructions and 1 load per 4, the game runtime's
mix in the simulator: rmLibrary 230k stores / 402k loads per 1.44M instructions)."""
import random, sys
n, out = int(sys.argv[1]), sys.argv[2]
r = random.Random(51)
ops = ['x = x * {k}u + {j}u;', 'x ^= x >> {s};', 'x += (x << {s}) ^ {k}u;', 'y = y - x + {k}u;',
       'y ^= (y << {s}) | {j}u;', 'x = (x + y) ^ {k}u;',
       'stk[{a}] = x;', 'stk[{a}] = y;', 'x += tab[(y >> {s}) & 12287u];', 'y ^= stk[{a}];']
w = [6, 6, 6, 6, 6, 6, 4, 4, 3, 3]
with open(out, 'w') as f:
    f.write('#include <stdint.h>\nextern volatile uint32_t stk[64]; extern const uint32_t tab[12288];\n')
    for i in range(n):
        f.write(f'__attribute__((noinline)) uint32_t g{i}(uint32_t x) {{ uint32_t y = {r.randrange(1 << 31)}u;\n')
        for _ in range(14):
            f.write('    ' + r.choices(ops, w)[0].format(k=r.randrange(3, 1 << 20) | 1, j=r.randrange(1, 2047), s=r.randrange(1, 18), a=r.randrange(64)) + '\n')
        f.write('    return x ^ y; }\n')
    f.write('typedef uint32_t (*fn_t)(uint32_t);\nconst fn_t gtab[%d] = {%s};\n' % (n, ', '.join(f'g{i}' for i in range(n))))
