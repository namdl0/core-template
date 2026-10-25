/* Bit-exact C model of the UFO 50 blitter. See blit_model.h and docs/BLITTER.md. */
#include "blit_model.h"
#include <string.h>
#include <stdlib.h>
#include <math.h>

uint32_t bm_alpha_word(double alpha, const uint8_t *levels, int nlevels, int *exact) {
    if (exact) *exact = 1;
    if (!(alpha < 1)) return 255;                 /* also NaN: the software path does not scale */
    if (alpha <= 0) return BM_ALT1;               /* a255 = a16 = 0: nothing drawn (see BLITTER.md) */
    uint32_t a255 = (uint32_t)(255.0 * alpha + 0.5);
    int64_t a0 = (int64_t)(alpha * 65536.0 + 0.5); if (a0 > 65535) a0 = 65535;
    int64_t lo = 0, hi = 65535;
    for (int k = 0; k < nlevels; k++) {
        int64_t s = levels[k], t = (int64_t)(uint32_t)((double)s * alpha + 0.5);
        /* (s*A + 0x8000) >> 16 == t */
        int64_t l = t * 65536 - 32768, h = (t + 1) * 65536 - 32769;
        l = l <= 0 ? 0 : (l + s - 1) / s; h = h < 0 ? -1 : h / s;
        if (l > lo) lo = l; if (h < hi) hi = h;
    }
    int64_t a16;
    if (lo > hi) { a16 = a0; if (exact) *exact = 0; }
    else a16 = a0 < lo ? lo : a0 > hi ? hi : a0;
    return a255 | BM_ALT1 | ((uint32_t)a16 << 16);
}

void bm_page_levels(BmPage *pg) {
    uint8_t seen[256] = {0}; pg->nlevels = 0;
    for (int i = 0; i < 256; i++) { uint32_t a = pg->pal[i] >> 24; if (a && a != 255 && !seen[a]) { seen[a] = 1; pg->levels[pg->nlevels++] = (uint8_t)a; } }
}

int bm_index_page(const uint32_t *rgba, int w, int h, uint8_t *idx, uint32_t *pal) {
    /* open-addressing hash colour -> index */
    enum { HS = 4096 };
    uint32_t key[HS]; int16_t val[HS]; memset(val, -1, sizeof val);
    int n = 1; pal[0] = 0; for (int i = 1; i < 256; i++) pal[i] = 0;
    for (long p = 0; p < (long)w * h; p++) {
        uint32_t c = rgba[p];
        if (!(c >> 24)) { idx[p] = 0; continue; }
        uint32_t hsh = (c * 2654435761u) >> 20;
        while (val[hsh] >= 0 && key[hsh] != c) hsh = (hsh + 1) & (HS - 1);
        if (val[hsh] < 0) { if (n == 256) return -1; key[hsh] = c; val[hsh] = (int16_t)n; pal[n++] = c; }
        idx[p] = (uint8_t)val[hsh];
    }
    return n;
}

void bm_exec(const uint32_t w[BM_CMD_WORDS], const BmPage *pg, BmSurf *dst, const int32_t *mapx, const int32_t *mapy) {
    uint32_t op = BM_OP(w[0]); int mode = (int)BM_BLEND(w[0]), fog = !!(w[0] & BM_FOG);
    int dx = w[1] & 0xFFFF, dy = w[1] >> 16, W = w[2] & 0xFFFF, H = w[2] >> 16;
    int sx = w[3] & 0xFFFF, sy = w[3] >> 16;
    uint32_t col = w[4], aw = w[5];
    for (int j = 0; j < H; j++) {
        uint32_t *d = dst->px + (long)(dy + j) * dst->stride + dx;
        if (op == BM_CLEAR) { for (int i = 0; i < W; i++) d[i] = col; continue; }
        if (op == BM_FILL) {
            uint32_t sa = bm_src_alpha(255, aw);
            if (sa) for (int i = 0; i < W; i++) bm_blend(&d[i], col | 0xFF000000u, sa, mode);
            continue;
        }
        int ty;
        if (op == BM_BLIT_MAP) { if (mapy[j] < 0) continue; ty = sy + mapy[j]; }
        else ty = sy + ((w[0] & BM_FLIPY) ? H - 1 - j : j);
        const uint8_t *row = pg->idx + (long)ty * pg->stride + sx;
        for (int i = 0; i < W; i++) {
            int tx;
            if (op == BM_BLIT_MAP) { tx = mapx[i]; if (tx < 0) continue; }
            else tx = (w[0] & BM_FLIPX) ? W - 1 - i : i;
            uint32_t px = pg->pal[row[tx]];
            uint32_t sa = bm_src_alpha(px >> 24, aw);
            if (!sa) continue;
            bm_blend(&d[i], bm_tint(px, col, fog), sa, mode);
        }
    }
}

static uint32_t rd32(const uint8_t *m, uint32_t a) { uint32_t v; memcpy(&v, m + a, 4); return v; }

uint32_t bm_run_mem(uint8_t *mem, uint32_t memsize, const uint32_t *cmds, int ncmds) {
    (void)memsize;
    uint32_t dbase = 0, dstride = 0, tbase = 0, tstride = 0, fence = 0;
    BmPage pg; uint32_t pal[256]; memset(&pg, 0, sizeof pg); memset(pal, 0, sizeof pal);
    static int32_t mx[BM_MAX_W], my[BM_MAX_MAP_H];
    for (int c = 0; c + BM_CMD_WORDS <= ncmds; c += BM_CMD_WORDS) {
        const uint32_t *w = cmds + c;
        switch (BM_OP(w[0])) {
        case BM_SET_DST: dbase = w[1]; dstride = w[2] & 0xFFFF; break;
        case BM_SET_TEX:
            tbase = w[1]; tstride = w[2] & 0xFFFF;
            for (int i = 0; i < 256; i++) pal[i] = rd32(mem, w[3] + 4 * i);
            break;
        case BM_FENCE: fence = w[1]; break;
        case BM_BLIT: case BM_FILL: case BM_CLEAR: case BM_BLIT_MAP: {
            int W = w[2] & 0xFFFF, H = w[2] >> 16;
            if (W <= 0 || H <= 0) break;
            /* a destination pointer at the command's origin keeps the memory image byte-exact */
            BmSurf s = { (uint32_t *)(mem + dbase), (int)(dstride / 4) };
            pg.idx = mem + tbase; pg.stride = (int)tstride; pg.pal = pal;
            if (BM_OP(w[0]) == BM_BLIT_MAP) {
                for (int i = 0; i < W; i++) { int32_t v = (int32_t)rd32(mem, w[6] + 4 * i); mx[i] = v; }
                for (int j = 0; j < H; j++) { int32_t v = (int32_t)rd32(mem, w[7] + 4 * j); my[j] = v; }
            }
            bm_exec(w, &pg, &s, mx, my);
            break;
        }
        default: break;
        }
    }
    return fence;
}
