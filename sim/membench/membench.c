/* membench.c - CPU memory latency under real SDRAM contention, for the Verilator SoC (tb_soc +boot6=,
 * with a blitter command list preloaded as for firmware/bench: +preload= files from tools/blitbench.py)
 * and tools/rv32sim --soc (ufo50-ap). Runs from SDRAM like the game runtime (slot-6 image, stack in SDRAM).
 *
 * The scanout runs in ABGR8888 from the bench's destination surface throughout (as in the game).
 * Phases (p):
 *   0  idle bus (blitter idle; scanout only)
 *   1  the blitter replays the preloaded command list over and over (fed from the CPU loop, like the
 *      runtime's pump()), while the CPU runs the same work as in phase 0
 * Work per phase (w): 0 interpreter-like mix (skewed random calls over ~110 KiB of code with loads from a
 * 48 KiB table and stores, sim/membench/gen_funcs.py), 1 4096 back-to-back word stores, 2 D$ misses
 * (32-byte stride loads over 96 KiB), 3 I$ misses (one pass over 96 KiB of code).
 * Results go to DEBUG_OUT as 0xBE tt vvvv words like cachebench: id = 0x80 * p + 0x20 * w + k:
 *   k 0 cycles, 1..10 the SoC's memory counters 0x200..0x224 (MEMORY_MAP.md 3.1a, deltas), 11..16 SDRAM
 *   busy cycles per owner (0x240..0x254), 17 blitter PERF_BUSY delta, 18 blitter command-list passes.
 * Around each measured run BENCH 7f id / 7e id: tb_soc prints CPU memory latency histograms for it.
 * Then BENCH 01 0 and BENCH ff (done). */
#include <stdint.h>
#define REG(a) (*(volatile uint32_t *)(uintptr_t)(a))
#define DEBUG_OUT REG(0x80000FFCu)
#define SYSR(o)   REG(0x80000000u + (o))
#define BLT(o)    REG(0x80020000u + (o))
typedef uint32_t (*fn_t)(uint32_t);
extern const fn_t gtab[];
#define NF 640
static inline uint32_t rdcycle(void) { uint32_t c; __asm__ volatile ("rdcycle %0" : "=r"(c)); return c; }
static inline void dcache_invalidate(void) { __asm__ volatile ("nop\n.word 0x0000500F" ::: "memory"); }
static void put(uint32_t tag, uint32_t v) { DEBUG_OUT = 0xBE000000u | (tag << 16) | (v & 0xFFFF); }
static void result(uint32_t i, uint32_t v) { put(0x10, i); put(0x11, v >> 16); put(0x12, v); }

volatile uint32_t stk[64];
const uint32_t tab[12288] __attribute__((aligned(32))) = { 1 };   /* 48 KiB (in .rodata: no init loop) */
uint32_t big[24576] __attribute__((aligned(32)));
static volatile uint32_t sink;

/* blitter feeding (phase 1) */
static const uint32_t *cmds; static uint32_t ncmd, cpos, passes; static int feeding;
static void feed(void) {
    if (!feeding) return;
    uint32_t free_w = BLT(0x04) >> 16;
    while (free_w >= 8) {
        if (cpos >= ncmd) { cpos = 0; passes++; }
        for (int k = 0; k < 8; k++) BLT(0x8000) = cmds[cpos + k];
        cpos += 8; free_w -= 8;
    }
}

static uint32_t snap[18];
static void take(uint32_t *s) {
    for (int i = 0; i < 10; i++) s[i] = SYSR(0x200 + 4 * i);
    for (int i = 0; i < 6; i++) s[10 + i] = SYSR(0x240 + 4 * i);
    s[16] = BLT(0x14); s[17] = passes;
}
static void report(uint32_t id, uint32_t cyc) {
    uint32_t now[18]; take(now);
    result(id, cyc);
    for (int i = 0; i < 18; i++) result(id + 1 + i, now[i] - snap[i]);
}

static void work(int w) {
    if (w == 0) {
        uint32_t r = 12345, x = 7;
        for (int c = 0; c < 6000; c++) {
            r = r * 1103515245u + 12345u;
            uint32_t h = r >> 16;
            int f = (h & 3) ? (int)(h % 96u) : (int)(h % NF);           /* 3/4 of the calls in a hot 18 KiB */
            x = gtab[f](x + tab[(r >> 3) % 12288u]);
            if ((c & 7) == 7) feed();
        }
        sink = x;
    } else if (w == 1) {
        volatile uint32_t *p = (volatile uint32_t *)0x13100000u;
        for (int rep = 0; rep < 4; rep++) {
            for (int i = 0; i < 1024; i++) p[i] = (uint32_t)i;
            feed();
        }
    } else if (w == 2) {
        uint32_t s = 0;
        for (int rep = 0; rep < 2; rep++) {
            for (int i = 0; i < 24576; i += 8) { s += big[i]; if ((i & 1023) == 0) feed(); }
        }
        sink = s;
    } else {
        uint32_t x = 1;
        for (int i = 0; i < NF; i++) { x = gtab[i](x); if ((i & 15) == 0) feed(); }
        sink = x;
    }
}

int main(void)
{
    const uint32_t *h = (const uint32_t *)0x11000000u;
    int have = h[0] == 0x484E4342u;            /* 'BNCH' header of tools/blitbench.py */
    uint32_t fb = have ? (0x10000000u + ((h[2] * 4) & ~0xFFu)) : 0x13A00000u;
    if (have) { ncmd = h[1] & ~7u; cmds = (const uint32_t *)0x11000100u; }
    REG(0x80000108u) = fb;                     /* FB_ADDR */
    REG(0x80000110u) = 1u | 4u;                /* VID_CTRL: scanout, ABGR8888 */
    while (SYSR(0x100) & 2u) { }
    for (int i = 0; i < 24576; i++) big[i] = i;
    for (int p = 0; p < 2; p++) {
        if (p == 1) {
            if (!have) break;
            BLT(0x08) = 4; feeding = 1; cpos = 0; passes = 0;
            feed();
            { uint32_t t = rdcycle(); while (rdcycle() - t < 20000u) feed(); }   /* the blitter is running */
        }
        for (int w = 0; w < 4; w++) {
            work(w);                            /* warm the caches (and the bus pattern) */
            if (w == 2) dcache_invalidate();
            take(snap);
            put(0x7F, 0x80 * p + 0x20 * w);    /* tb_soc: latency histograms from here */
            uint32_t t0 = rdcycle();
            work(w);
            uint32_t t1 = rdcycle();
            put(0x7E, 0x80 * p + 0x20 * w);    /* tb_soc: print them */
            report(0x80 * p + 0x20 * w, t1 - t0);
        }
        feeding = 0;
        while ((BLT(0x04) & 5u) != 4u) { }
    }
    put(0x01, 0);
    put(0xFF, 0);
    DEBUG_OUT = 0x45000000u;   /* DBG_EXIT 0 (rv32sim) */
    for (;;) { }
}
