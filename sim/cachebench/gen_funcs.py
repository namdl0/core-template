#!/usr/bin/env python3
"""gen_funcs.py N OUT.c - N leaf functions of straight-line integer code (~170 bytes each) for
the cache benchmark (cachebench.c): a code footprint much larger than a 16 KiB I$."""
import random, sys
n, out = int(sys.argv[1]), sys.argv[2]
r = random.Random(50)
ops = ['x = x * {k}u + {j}u;', 'x ^= x >> {s};', 'x += (x << {s}) ^ {k}u;', 'y = y - x + {k}u;',
       'y ^= (y << {s}) | {j}u;', 'x = (x + y) ^ {k}u;']
with open(out, 'w') as f:
    f.write('#include <stdint.h>\n')
    for i in range(n):
        f.write(f'__attribute__((noinline)) uint32_t f{i}(uint32_t x) {{ uint32_t y = {r.randrange(1 << 31)}u;\n')
        for _ in range(16):
            f.write('    ' + r.choice(ops).format(k=r.randrange(3, 1 << 20) | 1, j=r.randrange(1, 2047), s=r.randrange(1, 31)) + '\n')
        f.write('    return x ^ y; }\n')
    f.write('typedef uint32_t (*fn_t)(uint32_t);\nconst fn_t ftab[%d] = {%s};\n' % (n, ', '.join(f'f{i}' for i in range(n))))
