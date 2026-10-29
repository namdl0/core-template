/* cachebench.c - CPU cache benchmark for the Verilator SoC (tb_soc +boot6=) and tools/rv32sim --soc
 * (ufo50-ap), to compare the RTL's cycle counts with the simulator's cache model and to show the
 * cache sizes the CPU really has.
 *
 * Runs from SDRAM like the game runtime (slot-6 image at 0x12880000, stack in SDRAM). Results go to
 * DEBUG_OUT as benchmark words 0xBE tt vvvv: for result i, tag 0x10 = i, 0x11 = cycles[31:16],
 * 0x12 = cycles[15:0]; then BENCH 01 0 and BENCH ff (the testbench's pass/done), then the runtime's
 * exit word (rv32sim stops there).
 *   0..7   I$ size: cycles of one pass over F KiB of code (functions called in address order, 3rd pass),
 *          F = 8, 12, 24, 28, 40, 56, 72, 96
 *   8..15  D$ size: cycles of one pass of 32-byte-stride loads over the same footprints (3rd pass)
 *   16     interpreter-like mix: skewed random calls over ~100 KiB of code + loads from a 48 KiB table
 *   17     the same with dcache_invalidate() every 256 calls (the runtime invalidates per frame / DMA)
 *   18     stores: 64 KiB written word by word (write-through, no allocate)
 *   19     the hello firmware's march: 256 KiB written, dcache_invalidate(), read back and checked
 *   20     hello's mem_test() itself on 64 KiB at HEAP_BASE (two passes)
 *   21..28 hello's march write loop (16384 stores) at word offset 0..7 of an I$ line (align.S)
 */
#include <stdint.h>
#define DEBUG_OUT (*(volatile uint32_t *)0x80000FFCu)
typedef uint32_t (*fn_t)(uint32_t);
extern const fn_t ftab[];
#define NF 640
static inline uint32_t rdcycle(void) { uint32_t c; __asm__ volatile ("rdcycle %0" : "=r"(c)); return c; }
static inline void dcache_invalidate(void) { __asm__ volatile (".word 0x0000500F" ::: "memory"); }
static void put(uint32_t tag, uint32_t v) { DEBUG_OUT = 0xBE000000u | (tag << 16) | (v & 0xFFFF); }
static void result(uint32_t i, uint32_t cyc) { put(0x10, i); put(0x11, cyc >> 16); put(0x12, cyc); }

static uint32_t table[12288] __attribute__((aligned(32)));   /* 48 KiB */
uint32_t big[24576] __attribute__((aligned(32)));   /* 96 KiB for the D$ footprints over 48 KiB */
static volatile uint32_t sink;

static uint32_t code_pass(int n) { uint32_t x = 1; for (int i = 0; i < n; i++) x = ftab[i](x); return x; }
static uint32_t data_pass(int words) { uint32_t s = 0; for (int i = 0; i < words; i += 8) s += table[i]; return s; }
__attribute__((noinline)) static int mem_test(uint32_t base, uint32_t bytes)
{
    uint32_t *p = (uint32_t *)(uintptr_t)base;
    uint32_t n = bytes / 4;
    for (int pass_no = 0; pass_no < 2; pass_no++) {
        uint32_t seed = pass_no ? 0xFFFFFFFFu : 0;
        for (uint32_t i = 0; i < n; i++) p[i] = ((base + i * 4) * 2654435761u) ^ seed;
        __asm__ volatile (".word 0x0000500F" ::: "memory");
        for (uint32_t i = 0; i < n; i++) if (p[i] != (((base + i * 4) * 2654435761u) ^ seed)) return 0;
    }
    return 1;
}

int main(void)
{
    static const int kb[8] = { 8, 12, 24, 28, 40, 56, 72, 96 };
    for (int i = 0; i < 12288; i++) table[i] = i * 2654435761u;
    for (int i = 0; i < 24576; i++) big[i] = i;
    for (int k = 0; k < 8; k++) {
        int n = 0;   /* the functions are laid out in order: the first n span kb[k] KiB */
        while (n < NF && (uintptr_t)ftab[n] - (uintptr_t)ftab[0] < (uintptr_t)kb[k] * 1024u) n++;
        uint32_t t = 0;
        for (int p = 0; p < 3; p++) { uint32_t t0 = rdcycle(); sink = code_pass(n); t = rdcycle() - t0; }
        result(k, t);
    }
    for (int k = 0; k < 8; k++) {
        int words = kb[k] * 256; uint32_t t = 0;
        for (int p = 0; p < 3; p++) {
            uint32_t t0 = rdcycle(); uint32_t s = 0;
            if (words <= 12288) s = data_pass(words);
            else for (int i = 0; i < words; i += 8) s += big[i];
            sink = s; t = rdcycle() - t0;
        }
        result(8 + k, t);
    }
    for (int v = 0; v < 2; v++) {
        uint32_t r = 12345, x = 7, t0 = rdcycle();
        for (int c = 0; c < 12000; c++) {
            r = r * 1103515245u + 12345u;
            uint32_t h = r >> 16;
            int f = (h & 3) ? (int)(h % 96u) : (int)(h % NF);           /* 3/4 of the calls in a hot 16 KiB */
            x = ftab[f](x + table[(r >> 3) % 12288u] + table[h & 2047]);
            if (v && (c & 255) == 255) dcache_invalidate();
        }
        sink = x; result(16 + v, rdcycle() - t0);
    }
    {
        volatile uint32_t *w = (volatile uint32_t *)0x13100000u;
        uint32_t t0 = rdcycle();
        for (int i = 0; i < 16384; i++) w[i] = (uint32_t)i;
        result(18, rdcycle() - t0);
        uint32_t *m = (uint32_t *)0x13200000u, bad = 0;
        t0 = rdcycle();
        for (uint32_t i = 0; i < 65536; i++) m[i] = i * 2654435761u;
        dcache_invalidate();
        for (uint32_t i = 0; i < 65536; i++) bad += m[i] != i * 2654435761u;
        result(19, rdcycle() - t0);
        t0 = rdcycle();
        int ok = mem_test(0x13100000u, 65536u);
        result(20, rdcycle() - t0);
        typedef void (*sl_t)(volatile uint32_t *, uint32_t);
        extern void store_loop_0(volatile uint32_t *, uint32_t), store_loop_1(volatile uint32_t *, uint32_t),
            store_loop_2(volatile uint32_t *, uint32_t), store_loop_3(volatile uint32_t *, uint32_t),
            store_loop_4(volatile uint32_t *, uint32_t), store_loop_5(volatile uint32_t *, uint32_t),
            store_loop_6(volatile uint32_t *, uint32_t), store_loop_7(volatile uint32_t *, uint32_t);
        static const sl_t sl[8] = { store_loop_0, store_loop_1, store_loop_2, store_loop_3,
                                    store_loop_4, store_loop_5, store_loop_6, store_loop_7 };
        for (int k = 0; k < 8; k++) {
            t0 = rdcycle(); sl[k]((volatile uint32_t *)0x13100000u, 16384u); result(21 + k, rdcycle() - t0);
        }
        put(0x01, bad + !ok);
    }
    put(0xFF, 0);
    DEBUG_OUT = 0x45000000u;   /* DBG_EXIT 0 (rv32sim) */
    for (;;) { }
}
