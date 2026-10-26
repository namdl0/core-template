/*
 * bench/main.c - blitter benchmark on the full SoC (simulation only, not a bitstream image).
 *
 * The testbench preloads (tb_soc.cpp +preload=, tools/blitbench.py builds the files):
 *   SDRAM +0          : the blitter memory image from sim/periph/model/blitgen (pages, palettes,
 *                       BLIT_MAP tables, destination surfaces); command addresses are offsets into it
 *   SDRAM +0x01000000 : header {magic 'BNCH', n command words, dst word offset, dst words}, then
 *                       the command words from +0x01000100
 *   SDRAM +0x01800000 : expected destination words (C model result)
 * It scans the destination out in ABGR8888 (realistic SDRAM contention), runs the command list
 * once, then reports through DEBUG_OUT: 0xBE tt vvvv markers (tb prints "BENCH tt v"):
 *   10/11 total cycles hi/lo, 12/13 PERF_BUSY hi/lo, 14/15 PERF_MEMWAIT hi/lo,
 *   16/17 PERF_PIXELS hi/lo, 01 mismatching words (0 = pass), FF done.
 */
#include <stdint.h>
#include "soc.h"

#define DBG       REG32(SYS_BASE + 0xFFC)
#define BLT(r)    REG32(BLIT_BASE + (r))
#define HDR       0x01000000u
#define CMDS      0x01000100u
#define EXPECT    0x01800000u

static void rep(uint32_t tag, uint32_t v) { DBG = 0xBE000000u | (tag << 16) | (v & 0xFFFF); }
static void rep32(uint32_t tag, uint32_t v) { rep(tag, v >> 16); rep(tag + 1, v); }

void trap_handler(uint32_t mcause, uint32_t mepc, uint32_t mtval)
{
    (void)mepc; (void)mtval;
    DBG = 0xDEAD0000u | (mcause & 0xFFFF);
    for (;;) { }
}

int main(void)
{
    dcache_invalidate();
    const uint32_t *h = (const uint32_t *)(uintptr_t)(SDRAM_BASE + HDR);
    if (h[0] != 0x484E4342u) { rep(0x01, 0xFFFF); rep(0xFF, 0); for (;;) { } }   /* 'BNCH' */
    uint32_t n = h[1], dbase = h[2], dwords = h[3];
    const uint32_t *c = (const uint32_t *)(uintptr_t)(SDRAM_BASE + CMDS);

    /* scan the destination out as ABGR8888 while blitting */
    FB_ADDR = SDRAM_BASE + ((dbase * 4) & ~0xFFu);
    VID_CTRL = VID_CTRL_SCANOUT | (1u << 2);
    while (VID_STATUS & VID_STATUS_SWAP_PEND) { }

    BLT(0x08) = 4;
    uint32_t b0 = BLT(0x14), w0 = BLT(0x1C), p0 = BLT(0x18), t0 = rdcycle();
    for (uint32_t i = 0; i < n; i += 8) {
        while ((BLT(0x04) >> 16) < 8) { }
        for (int k = 0; k < 8; k++) REG32(BLIT_BASE + 0x8000) = c[i + k];
    }
    while (BLT(0x0C) != 0xD0D0u || (BLT(0x04) & 5) != 4) { }
    uint32_t t1 = rdcycle();
    rep32(0x10, t1 - t0); rep32(0x12, BLT(0x14) - b0); rep32(0x14, BLT(0x1C) - w0); rep32(0x16, BLT(0x18) - p0);

    dcache_invalidate();
    const uint32_t *d = (const uint32_t *)(uintptr_t)(SDRAM_BASE + dbase * 4);
    const uint32_t *e = (const uint32_t *)(uintptr_t)(SDRAM_BASE + EXPECT);
    uint32_t bad = 0;
    for (uint32_t i = 0; i < dwords; i++) if (d[i] != e[i]) {
        if (bad < 6) { rep32(0x20, i); rep32(0x22, d[i]); rep32(0x24, e[i]); }   /* word index (in region), got, expected */
        bad++;
    }
    rep(0x01, bad > 0xFFFF ? 0xFFFF : bad);
    rep(0xFF, 0);
    for (;;) { }
}
