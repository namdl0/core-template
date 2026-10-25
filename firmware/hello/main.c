/*
 * main.c - UFO50 Pocket SoC, milestone M3 exit test ("hello").
 *
 * Shows on screen: CPU clock (nominal and measured against the 60 Hz video timing),
 * cache/FPU configuration, data slots and a CRC32 of slot 0, a 0x0180 read test,
 * an SDRAM test, memory bandwidth, a double-precision FPU benchmark, the blitter/mixer
 * port stubs, and then the live button state with a double-buffered animation.
 *
 * Build with -DSIM for the simulation testbench (small sizes, no waiting).
 */
#include <stdint.h>
#include "soc.h"
#include "console.h"
#include "dataslot.h"

#ifdef SIM
#define MEMTEST_BYTES   (64u * 1024u)
#define MEMTEST_BASE    HEAP_BASE
#define BW_BYTES        (16u * 1024u)
#define FPU_N           200
#define CLK_FRAMES      0
#define CRC_MAX         (4u * 1024u)
#else
#define MEMTEST_BYTES   (FB0_ADDR - SDRAM_BASE)       /* 63.5 MB: everything below the framebuffers */
#define MEMTEST_BASE    SDRAM_BASE
#define BW_BYTES        (1u * 1024u * 1024u)
#define FPU_N           100000
#define CLK_FRAMES      60
#define CRC_MAX         0xFFFFFFFFu
#endif

#define DEBUG_OUT REG32(SYS_BASE + 0xFFC)    /* write-only marker, ignored by hardware (simulation hook) */

static uint32_t clk_hz;

static void label(const char *s) { con_color(C_CYAN, C_NAVY); con_puts(s); con_color(C_WHITE, C_NAVY); }
static void pass(int ok) { con_color(ok ? C_GREEN : C_RED, C_NAVY); con_puts(ok ? "PASS" : "FAIL"); con_color(C_WHITE, C_NAVY); }

static double secs(uint64_t cyc) { return (double)cyc / (double)clk_hz; }
static void mbps(uint32_t bytes, uint64_t cyc) { con_fixed((double)bytes / secs(cyc) / 1e6, 1); con_puts(" MB/s"); }

void trap_handler(uint32_t mcause, uint32_t mepc, uint32_t mtval)
{
    VID_CTRL = VID_CTRL_SCANOUT;
    con_color(C_WHITE, C_RED);
    con_goto(0, 26);
    con_puts("TRAP mcause "); con_hex(mcause, 8);
    con_puts(" mepc "); con_hex(mepc, 8);
    con_puts(" mtval "); con_hex(mtval, 8);
    DEBUG_OUT = 0xDEAD0000u | (mcause & 0xFFFF);
    for (;;) { }
}

/* ------------------------------------------------------------------ CRC32 */
static uint32_t crc_table[256];
static void crc_init(void)
{
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
        crc_table[i] = c;
    }
}
static uint32_t crc32(uint32_t crc, const uint8_t *p, uint32_t n)
{
    crc = ~crc;
    while (n--) crc = crc_table[(crc ^ *p++) & 0xFF] ^ (crc >> 8);
    return ~crc;
}

/* ------------------------------------------------------------------ SDRAM tests */
static int bus_test(uint32_t *fail_addr)
{
    volatile uint32_t *p = (volatile uint32_t *)UNCACHED(HEAP_BASE);
    for (int b = 0; b < 32; b++) {                       /* data bus: walking one */
        p[0] = 1u << b;
        if (p[0] != (1u << b)) { *fail_addr = (uint32_t)(uintptr_t)p; return 0; }
    }
    volatile uint32_t *base = (volatile uint32_t *)UNCACHED(SDRAM_BASE);
    for (int k = 2; k < 26; k++) base[(1u << k) >> 2] = 0xA5000000u | k;   /* address bus */
    base[0] = 0x5A5A5A5Au;
    for (int k = 2; k < 26; k++)
        if (base[(1u << k) >> 2] != (0xA5000000u | k)) { *fail_addr = SDRAM_BASE + (1u << k); return 0; }
    if (base[0] != 0x5A5A5A5Au) { *fail_addr = SDRAM_BASE; return 0; }
    return 1;
}

static int mem_test(uint32_t base, uint32_t bytes, uint32_t *fail_addr, int row)
{
    uint32_t *p = (uint32_t *)(uintptr_t)base;
    uint32_t n = bytes / 4;
    for (int pass_no = 0; pass_no < 2; pass_no++) {
        uint32_t seed = pass_no ? 0xFFFFFFFFu : 0;
        for (uint32_t i = 0; i < n; i++) {
            p[i] = ((base + i * 4) * 2654435761u) ^ seed;
            if ((i & 0xFFFFF) == 0) { con_goto(31, row); con_dec(pass_no + 1); con_puts(": wr "); con_dec((i * 4) >> 20); con_puts("MB  "); }
        }
        dcache_invalidate();
        for (uint32_t i = 0; i < n; i++) {
            if (p[i] != (((base + i * 4) * 2654435761u) ^ seed)) { *fail_addr = base + i * 4; return 0; }
            if ((i & 0xFFFFF) == 0) { con_goto(31, row); con_dec(pass_no + 1); con_puts(": rd "); con_dec((i * 4) >> 20); con_puts("MB  "); }
        }
    }
    con_goto(31, row); con_puts("             ");
    return 1;
}

/* ------------------------------------------------------------------ FPU benchmark */
static double __attribute__((noipa)) bench_basel(int n)
{
    double s = 0.0;
    for (int i = 1; i <= n; i++) { double d = (double)i; s += 1.0 / (d * d); }
    return s;
}
static double __attribute__((noipa)) bench_fma(int n)
{
    double x = 0.0, a = 0.999999, b = 0.5;
    for (int i = 0; i < n; i++) x = __builtin_fma(x, a, b);
    return x;
}
static double __attribute__((noipa)) bench_sqrt(int n)
{
    double s = 0.0;
    for (int i = 0; i < n; i++) s += __builtin_sqrt((double)i);
    return s;
}

/* ------------------------------------------------------------------ peripherals */
static int periph_test(uint32_t base, uint32_t id, uint32_t src, uint32_t dst)
{
    if (REG32(base) != id) return 0;
    REG32(base + 4) = 0x12345678u;
    REG32(base + 0x1C) = ~0x12345678u;
    if (REG32(base + 4) != 0x12345678u || REG32(base + 0x1C) != ~0x12345678u) return 0;
    uint32_t *s = (uint32_t *)(uintptr_t)src, *d = (uint32_t *)(uintptr_t)dst;
    for (int i = 0; i < 8; i++) { s[i] = id ^ (i * 0x01010101u); d[i] = 0; }
    REG32(base + 0x24) = src;
    REG32(base + 0x28) = dst;
    REG32(base + 0x20) = 1;
    while (REG32(base + 0x20) & 1) { }
    dcache_invalidate();
    for (int i = 0; i < 8; i++) if (d[i] != (id ^ (i * 0x01010101u))) return 0;
    return 1;
}

/* ------------------------------------------------------------------ live area */
static const char *key_names[16] = { "UP", "DN", "LT", "RT", "A", "B", "X", "Y",
                                     "L1", "R1", "L2", "R2", "L3", "R3", "SE", "ST" };

static void draw_live(uint16_t *fb, uint32_t frame, uint32_t keys)
{
    char b[48], *p = b;
    const char *s = "Frame ";
    while (*s) *p++ = *s++;
    p = fmt_dec(p, frame);
    while (p < b + 16) *p++ = ' ';
    *p = 0;
    con_text_at(fb, 0, 21, b, C_WHITE, C_NAVY);
    p = b; s = "cont1_key ";
    while (*s) *p++ = *s++;
    p = fmt_hex(p, keys, 8);
    con_text_at(fb, 16, 21, b, C_GREY, C_NAVY);

    int col = 0;
    for (int i = 0; i < 16; i++) {
        int on = (keys >> i) & 1;
        con_text_at(fb, col, 22, key_names[i], on ? C_BLACK : C_GREY, on ? C_YELLOW : C_NAVY);
        col += str_len(key_names[i]) + 1;
    }
    /* moving block: proves 60 Hz double buffering (no tearing, smooth motion) */
    fb_fill_rect(fb, 0, 192, FB_W, 16, C_BLACK);
    int x = (int)((frame * 3) % (FB_W - 24));
    fb_fill_rect(fb, x, 192, 24, 16, (keys & KEY_A) ? C_CYAN : C_ORANGE);
}

int main(void)
{
    clk_hz = SYS_CLK_HZ;
    DEBUG_OUT = 0x00000001u;
    con_init(C_NAVY);
    con_color(C_YELLOW, C_NAVY);
    con_puts("UFO50 Pocket SoC - M3 hello\n");
    con_color(C_WHITE, C_NAVY);

    /* ---- CPU */
    uint32_t cfg = SYS_CONFIG, misa = read_misa();
    label("CPU  "); con_puts("VexRiscv RV32");
    for (const char *e = "IEMAFDQCBV"; *e; e++) if (misa & (1u << (*e - 'A'))) con_putc(*e);   /* canonical order */
    con_puts("  ");
    con_fixed(clk_hz / 1e6, 3); con_puts(" MHz\n");
    label("     "); con_puts("I$ "); con_dec(cfg & 0xFF); con_puts("K "); con_dec((cfg >> 16) & 15);
    con_puts("-way  D$ "); con_dec((cfg >> 8) & 0xFF); con_puts("K "); con_dec((cfg >> 20) & 15);
    con_puts("-way  FPU "); con_puts((cfg >> 24) & 1 ? "F+D" : "none"); con_putc('\n');
    label("     "); con_puts("measured ");
    if (CLK_FRAMES) {
        wait_vblank();
        uint64_t t0 = mtime64(), c0 = rdcycle64();
        for (int i = 0; i < CLK_FRAMES; i++) wait_vblank();
        uint64_t t1 = mtime64(), c1 = rdcycle64();
        con_fixed((double)(t1 - t0) * 60.0 / (CLK_FRAMES ? CLK_FRAMES : 1) / 1e6, 3);
        con_puts(" MHz (rdcycle ");
        con_fixed((double)(c1 - c0) * 60.0 / (CLK_FRAMES ? CLK_FRAMES : 1) / 1e6, 3);
        con_puts(")\n");
    } else con_puts("(skipped)\n");
    DEBUG_OUT = 0x00000002u;

    /* ---- data slots */
    crc_init();
    label("SLOT ");
    int any = 0;
    for (uint16_t id = 0; id < 5; id++) {
        uint32_t sz;
        if (ds_slot_size(id, &sz)) { con_dec(id); con_putc(':'); con_dec(sz); con_putc(' '); any = 1; }
    }
    if (!any) con_puts("no files (all slots optional)");
    con_putc('\n');
    uint32_t s0;
    if (ds_slot_size(0, &s0)) {
        uint32_t n = s0 > CRC_MAX ? CRC_MAX : s0;
        label("     "); con_puts("slot0 crc32 ");
        dcache_invalidate();
        uint64_t c0 = rdcycle64();
        uint32_t crc = crc32(0, (const uint8_t *)(uintptr_t)SLOT0_ADDR, n);
        uint64_t c1 = rdcycle64();
        con_hex(crc, 8); con_puts("  "); con_fixed(secs(c1 - c0), 2); con_puts(" s\n");
        /* 0x0180: re-read the start of slot 0 into the heap and compare */
        uint32_t m = n < 4096 ? n : 4096;
        uint8_t *dst = (uint8_t *)(uintptr_t)HEAP_BASE;
        for (uint32_t i = 0; i < m; i++) dst[i] = 0xEE;
        int r = ds_read(0, 0, dst, (m + 3) & ~3u);
        int same = (r == 0);
        for (uint32_t i = 0; same && i < m; i++) same = dst[i] == ((const uint8_t *)(uintptr_t)SLOT0_ADDR)[i];
        label("     "); con_puts("0x0180 read "); con_dec(m); con_puts(" B: ");
        if (r) { con_color(C_RED, C_NAVY); con_puts("APF error "); con_dec((uint32_t)-r); con_color(C_WHITE, C_NAVY); }
        else pass(same);
        con_putc('\n');
    } else {
        label("     "); con_puts("slot0: no file, CRC skipped\n\n");
    }
    DEBUG_OUT = 0x00000003u;

    /* ---- SDRAM */
    uint32_t fa = 0;
    label("SDRAM"); con_puts(" init "); pass(SDRAM_STATUS & 1);
    con_puts("  bus "); int ok = bus_test(&fa); pass(ok);
    if (!ok) { con_puts(" @"); con_hex(fa, 8); }
    con_putc('\n');
    label("     "); con_dec(MEMTEST_BYTES >> 10); con_puts(" KB march ");
    uint64_t c0 = rdcycle64();
    ok = mem_test(MEMTEST_BASE, MEMTEST_BYTES, &fa, 8);
    uint64_t c1 = rdcycle64();
    con_goto(31, 8); pass(ok);
    if (!ok) { con_puts(" @"); con_hex(fa, 8); }
    else { con_putc(' '); con_fixed(secs(c1 - c0), 1); con_puts(" s"); }
    con_putc('\n');
    DEBUG_OUT = 0x00000004u;

    /* ---- bandwidth */
    {
        uint32_t *a = (uint32_t *)(uintptr_t)HEAP_BASE;
        uint32_t *b = (uint32_t *)(uintptr_t)(HEAP_BASE + BW_BYTES);
        uint32_t n = BW_BYTES / 4, sum = 0;
        uint64_t t0 = rdcycle64();
        for (uint32_t i = 0; i < n; i++) a[i] = i;
        uint64_t t1 = rdcycle64();
        dcache_invalidate();
        for (uint32_t i = 0; i < n; i += 4) sum += a[i] + a[i + 1] + a[i + 2] + a[i + 3];
        uint64_t t2 = rdcycle64();
        dcache_invalidate();
        for (uint32_t i = 0; i < n; i++) b[i] = a[i];
        uint64_t t3 = rdcycle64();
        label("BW   "); con_puts("wr "); mbps(BW_BYTES, t1 - t0);
        con_puts(" rd "); mbps(BW_BYTES, t2 - t1);
        con_puts("\n     cpy "); mbps(BW_BYTES, t3 - t2);
        con_puts(sum == (n / 2) * (n - 1) ? "  sum ok\n" : "  SUM BAD\n");
    }
    DEBUG_OUT = 0x00000005u;

    /* ---- FPU (double) */
    {
        uint64_t t0 = rdcycle64(); double s1 = bench_basel(FPU_N);
        uint64_t t1 = rdcycle64(); double s2 = bench_fma(FPU_N);
        uint64_t t2 = rdcycle64(); double s3 = bench_sqrt(FPU_N);
        uint64_t t3 = rdcycle64();
        label("FPU  "); con_puts("sum 1/i^2 "); con_fixed(s1, 9); con_puts("  ");
        con_dec((uint32_t)((t1 - t0) / FPU_N)); con_puts(" cyc/it\n");
        label("     "); con_puts("fma "); con_fixed(s2, 6); con_puts(" "); con_dec((uint32_t)((t2 - t1) / FPU_N));
        con_puts(" cyc  sqrt "); con_dec((uint32_t)((t3 - t2) / FPU_N)); con_puts(" cyc\n");
        /* reference values (computed on a PC with IEEE doubles, same operation order) */
#ifdef SIM
        int fok = s1 > 1.639946545 && s1 < 1.639946547 && s3 > 1878.342075 && s3 < 1878.342076 && s2 > 99.990050 && s2 < 99.990051;
#else
        int fok = s1 > 1.644924066 && s1 < 1.644924067 && s3 > 21081692.7 && s3 < 21081692.8 && s2 > 47581.3 && s2 < 47581.4;
#endif
        label("     "); con_puts("double results "); pass(fok); con_putc('\n');
    }
    DEBUG_OUT = 0x00000006u;

    /* ---- blitter / mixer port stubs */
    {
        label("PERIPH "); con_puts("blit ");
        pass(periph_test(BLIT_BASE, 0x424C4954u, HEAP_BASE + 0x200000, HEAP_BASE + 0x200100));
        con_puts("  mixer ");
        pass(periph_test(MIX_BASE, 0x4D495852u, HEAP_BASE + 0x200200, HEAP_BASE + 0x200300));
        con_putc('\n');
    }
    con_color(C_GREY, C_NAVY);
    con_goto(0, 20); con_puts("Live (A = cyan block):");
    DEBUG_OUT = 0x00000007u;

    /* ---- live loop, double buffered */
    int back = 1;
    uint32_t frame = 0;
    for (;;) {
        uint16_t *fb = con_fb(back);
        draw_live(fb, frame, CONT1_KEY);
        FB_ADDR = back ? FB1_ADDR : FB0_ADDR;
        while (VID_STATUS & VID_STATUS_SWAP_PEND) { }
        back ^= 1;
        frame++;
        DEBUG_OUT = 0x00010000u | (frame & 0xFFFF);
    }
}
