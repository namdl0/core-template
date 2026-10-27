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
 * Built with -DMIXSTRESS (make benchmix): 32 mixer voices (16 PCM16, 16 IMA ADPCM, looping,
 * different pitches and start points) play while the command list is replayed 3 times;
 * reports 30/31 mixer samples produced, 32 underruns, 33 max cycles per sample, 34 last.
 */
#include <stdint.h>
#include "soc.h"

#define DBG       REG32(SYS_BASE + 0xFFC)
#define BLT(r)    REG32(BLIT_BASE + (r))
#define HDR       0x01000000u
#define CMDS      0x01000100u
#define EXPECT    0x01800000u
#define MIX(r)    REG32(MIX_BASE + (r))
#define MV(v, r)  MIX(0x1000 + 64 * (v) + 4 * (r))
#define SND       0x02000000u           /* SDRAM offset of the stress sample data */

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
#ifndef NOSCAN
    FB_ADDR = SDRAM_BASE + ((dbase * 4) & ~0xFFu);
    VID_CTRL = VID_CTRL_SCANOUT | (1u << 2);
    while (VID_STATUS & VID_STATUS_SWAP_PEND) { }
#else
    VID_CTRL = 0;                   /* -DNOSCAN (make benchns): no framebuffer scanout, blitter alone */
#endif

#ifdef MIXSTRESS
    /* sample data: 8192 PCM16 frames (a ramp) and 16 KB of bytes played as ADPCM; seek table 0 */
    uint32_t *sp = (uint32_t *)(uintptr_t)(SDRAM_BASE + SND);
    for (uint32_t i = 0; i < 8192 / 2; i++) sp[i] = (i * 0x00050003u) ^ 0x12340000u;
    uint32_t *ap = (uint32_t *)(uintptr_t)(SDRAM_BASE + SND + 0x8000);
    for (uint32_t i = 0; i < 4096; i++) ap[i] = i * 2654435761u;
    uint32_t *sk = (uint32_t *)(uintptr_t)(SDRAM_BASE + SND + 0x10000);
    for (uint32_t i = 0; i < 128; i++) sk[i] = 0;
    MIX(0x08) = 4; MIX(0x08) = 1; MIX(0x10) = 0x4000;
    for (int g = 0; g < 8; g++) MIX(0x800 + 16 * g) = 0x4000;
    for (int v = 0; v < 32; v++) {
        int adpcm = v & 1;
        MV(v, 1) = (adpcm ? 1u : 0u) | (1u << 2) | (1u << 3) | ((uint32_t)(v & 7) << 4);
        MV(v, 2) = SND + (adpcm ? 0x8000u : 0u);
        MV(v, 3) = SND + 0x10000u;
        MV(v, 4) = adpcm ? 32768u : 8192u;
        MV(v, 5) = 0; MV(v, 6) = (uint32_t)v * 97u;
        MV(v, 7) = 40000u + (uint32_t)v * 1500u;             /* 0.61 .. 1.32 x */
        MV(v, 8) = 0x0400; MV(v, 11) = 0x80008000u;
        MV(v, 0) = 1;
    }
    rep(0x35, MIX(0x14));                                   /* underruns at start-up */
    { uint32_t tw = rdcycle(); while (rdcycle() - tw < 57750u * 5u) { } }   /* 5 ms settle */
    rep(0x36, MIX(0x14)); rep(0x37, MIX(0x18) >> 16);        /* start-up underruns, max cycles so far */
    uint32_t ms0 = MIX(0x0C), mu0 = MIX(0x14);
    for (int rep = 0; rep < 3; rep++) {
#endif
    BLT(0x08) = 4;
    uint32_t b0 = BLT(0x14), w0 = BLT(0x1C), p0 = BLT(0x18), t0 = rdcycle();
    for (uint32_t i = 0; i < n; i += 8) {
        while ((BLT(0x04) >> 16) < 8) { }
        for (int k = 0; k < 8; k++) REG32(BLIT_BASE + 0x8000) = c[i + k];
    }
    while (BLT(0x0C) != 0xD0D0u || (BLT(0x04) & 5) != 4) { }
    uint32_t t1 = rdcycle();
#ifdef MIXSTRESS
    rep32(0x10, t1 - t0); rep32(0x12, BLT(0x14) - b0); rep32(0x14, BLT(0x1C) - w0);
    }
    rep32(0x30, MIX(0x0C) - ms0); rep(0x32, MIX(0x14) - mu0);
    rep(0x33, MIX(0x18) >> 16); rep(0x34, MIX(0x18) & 0xFFFF);
    rep(0x01, 0); rep(0xFF, 0);
    for (;;) { }
#else
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
#endif
}
