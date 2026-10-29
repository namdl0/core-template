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
    put(0x01, 0); put(0xFF, 0);
    DEBUG_OUT = 0x45000000u;   /* DBG_EXIT 0 (rv32sim) */
    for (;;) { }
}
