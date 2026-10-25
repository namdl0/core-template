/* Unit checks of the blitter model's per-pixel datapath against the runtime's
 * reference (blend_px/tint_c copied verbatim from ufo50-ap runtime/src/render.c).
 * cc -O2 -o test_blit_unit test_blit_unit.c blit_model.c -lm */
#include "blit_model.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>

/* ---- verbatim from render.c (main @ afc4688) ---- */
static inline void blend_px(uint32_t *d, uint32_t src, double alpha, int mode, bool app) {
    uint32_t sa = (src >> 24) & 255;
    if (alpha < 1) sa = (uint32_t)(sa * alpha + 0.5);
    if (!sa) return;
    uint32_t dc = *d;
    int sr = src & 255, sg = (src >> 8) & 255, sb = (src >> 16) & 255;
    int dr = dc & 255, dg = (dc >> 8) & 255, db = (dc >> 16) & 255, da = (dc >> 24) & 255;
    if (mode == 1) {
        dr += sr * sa / 255; dg += sg * sa / 255; db += sb * sa / 255;
        if (dr > 255) dr = 255; if (dg > 255) dg = 255; if (db > 255) db = 255;
        da = da > (int)sa ? da : (int)sa;
    } else if (mode == 3) {
        dr -= sr * sa / 255; dg -= sg * sa / 255; db -= sb * sa / 255;
        if (dr < 0) dr = 0; if (dg < 0) dg = 0; if (db < 0) db = 0;
    } else {
        if (sa == 255) { *d = (src & 0xFFFFFF) | 0xFF000000u; if (!app) *d = src | 0xFF000000u; return; }
        dr = (sr * sa + dr * (255 - sa)) / 255; dg = (sg * sa + dg * (255 - sa)) / 255; db = (sb * sa + db * (255 - sa)) / 255;
        da = sa + da * (255 - sa) / 255;
    }
    *d = (uint32_t)dr | ((uint32_t)dg << 8) | ((uint32_t)db << 16) | ((uint32_t)da << 24);
}
static inline uint32_t tint_c(uint32_t px, uint32_t col, bool fog) {
    if (fog) return (px & 0xFF000000u) | (col & 0xFFFFFF);
    if ((col & 0xFFFFFF) == 0xFFFFFF) return px;
    uint32_t r = (px & 255) * (col & 255) / 255, g = ((px >> 8) & 255) * ((col >> 8) & 255) / 255,
             b = ((px >> 16) & 255) * ((col >> 16) & 255) / 255;
    return (px & 0xFF000000u) | r | (g << 8) | (b << 16);
}
/* ------------------------------------------------- */

static uint64_t rs = 88172645463325252ull;
static uint32_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return (uint32_t)rs; }

int main(void) {
    int fail = 0;
    for (uint32_t x = 0; x <= 65534; x++) if (bm_div255(x) != x / 255) { printf("div255 fails at %u\n", x); fail = 1; break; }
    /* alpha set: what GML code produces (k/100, k/20, k/255, accumulated 0.05/0.1 fades, 1/3...) */
    static double al[20000]; int na = 0;
    for (int k = 0; k <= 100; k++) al[na++] = k / 100.0;
    for (int k = 0; k <= 255; k++) al[na++] = k / 255.0;
    for (int k = 0; k <= 64; k++) al[na++] = k / 64.0;
    { double a = 1; for (int k = 0; k < 40; k++) { a -= 0.05; al[na++] = a; } }
    { double a = 0; for (int k = 0; k < 40; k++) { a += 0.1; al[na++] = a; } }
    { double a = 1; for (int k = 0; k < 120; k++) { a -= 1 / 60.0; al[na++] = a; } }
    for (int k = 0; k < 5000; k++) al[na++] = (rnd() % 1000001) / 1000000.0;
    for (int k = 0; k < 3000; k++) al[na++] = (double)rnd() / 4294967296.0;
    /* 1) every single texel alpha level 1..254 alone: solver must always be exact */
    long nsolve = 0, nfail1 = 0;
    for (int a = 0; a < na; a++) for (int s = 1; s <= 255; s++) {
        uint8_t lv = (uint8_t)s; int ex;
        uint32_t aw = bm_alpha_word(al[a], &lv, s == 255 ? 0 : 1, &ex);
        uint32_t want = al[a] < 1 ? (uint32_t)(s * al[a] + 0.5) : (uint32_t)s;
        if (al[a] < 0) want = 0;
        nsolve++; if (bm_src_alpha((uint32_t)s, aw) != want) nfail1++;
    }
    /* 2) without the solver (plain round(alpha*65536)): how often is it off? */
    long nround = 0;
    for (int a = 0; a < na; a++) if (al[a] < 1 && al[a] > 0) for (int s = 1; s < 255; s++) {
        uint32_t a16 = (uint32_t)(al[a] * 65536 + 0.5); if (a16 > 65535) a16 = 65535;
        if (((s * a16 + 0x8000) >> 16) != (uint32_t)(s * al[a] + 0.5)) nround++;
    }
    /* 3) real level sets: all levels 1..254 together (worst case) and random 9-level sets */
    long nsets = 0, nsetfail = 0, nall = 0;
    uint8_t all[254]; for (int s = 1; s < 255; s++) all[s - 1] = (uint8_t)s;
    for (int a = 0; a < na; a++) { int ex; bm_alpha_word(al[a], all, 254, &ex); nall += !ex; }
    for (int t = 0; t < 20000; t++) {
        uint8_t lv[9]; for (int k = 0; k < 9; k++) lv[k] = (uint8_t)(1 + rnd() % 254);
        int ex; bm_alpha_word(al[rnd() % na], lv, 9, &ex); nsets++; nsetfail += !ex;
    }
    /* 4) full pixel path vs blend_px(tint_c()) incl. all modes, fog, tint, app/non-app */
    long npx = 0, npxfail = 0;
    for (int t = 0; t < 3000000; t++) {
        uint32_t src = rnd(), dstv = rnd(), col = rnd() & 0xFFFFFF;
        int r = rnd() % 4; if (r == 0) src |= 0xFF000000u; else if (r == 1) src &= 0xFFFFFF;
        if (rnd() % 3 == 0) col = 0xFFFFFF;
        int mode = (int[]){0, 1, 3, 0}[rnd() % 4], fog = rnd() % 5 == 0;
        double alpha = rnd() % 2 ? 1.0 : al[rnd() % na]; if (alpha < 0) alpha = -alpha; /* negative: UB in C (see BLITTER.md) */
        uint8_t lv = (uint8_t)(src >> 24);
        uint32_t aw = bm_alpha_word(alpha, &lv, (lv && lv != 255) ? 1 : 0, NULL);
        uint32_t d1 = dstv, d2 = dstv;
        blend_px(&d1, tint_c(src, col, fog), alpha, mode, rnd() & 1);
        uint32_t sa = bm_src_alpha(src >> 24, aw);
        if (sa) bm_blend(&d2, bm_tint(src, col, fog), sa, mode);
        npx++; if (d1 != d2) { if (npxfail < 5) printf("px mismatch src %08x dst %08x col %06x mode %d fog %d alpha %.17g: %08x vs %08x\n", src, dstv, col, mode, fog, alpha, d1, d2); npxfail++; }
    }
    printf("div255 exhaustive 0..65534: %s\n", fail ? "FAIL" : "ok");
    printf("alpha, single level (solver): %ld cases, %ld mismatches\n", nsolve, nfail1);
    printf("alpha, plain round(alpha*65536), no solver: %ld LSB mismatches of %ld\n", nround, (long)na * 253);
    printf("alpha, all 254 levels at once: no exact a16 for %ld of %d alphas\n", nall, na);
    printf("alpha, random 9-level sets: no exact a16 for %ld of %ld\n", nsetfail, nsets);
    printf("pixel path vs blend_px(tint_c): %ld cases, %ld mismatches\n", npx, npxfail);
    return fail || nfail1 || npxfail;
}
