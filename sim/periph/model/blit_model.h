/* Bit-exact, cycle-free C model of the UFO 50 blitter (src/fpga/core/periph/blit_*.v).
 * Command format and semantics: docs/BLITTER.md. The same source is vendored into the
 * runtime (runtime/src/hw/) so the runtime can execute its display list through the
 * model instead of rc_exec (build `make blitmodel`). */
#ifndef BLIT_MODEL_H
#define BLIT_MODEL_H
#include <stdint.h>

enum { BM_BLIT = 0, BM_FILL = 1, BM_CLEAR = 2, BM_BLIT_MAP = 3, BM_SET_DST = 4, BM_SET_TEX = 5, BM_FENCE = 6, BM_NOP = 7 };
#define BM_CMD_WORDS 8
#define BM_OP(w0)    ((w0) & 15u)
#define BM_FLIPX     (1u << 4)
#define BM_FLIPY     (1u << 5)
#define BM_BLEND(w0) (((w0) >> 6) & 3u)    /* 0 normal, 1 add, 3 subtract (2 = normal) */
#define BM_FOG       (1u << 8)
#define BM_IRQ       (1u << 9)             /* FENCE: raise the interrupt */
/* alpha word (w5): [7:0] a255 = (uint)(255*alpha+0.5), [8] alpha < 1, [31:16] a16 */
#define BM_ALT1      (1u << 8)

/* hardware limits (the CPU side splits or falls back beyond these) */
#define BM_MAX_W        512    /* destination width of one command */
#define BM_MAX_MAP_H    1024   /* BLIT_MAP rows (mapy table) */
#define BM_MAX_SPAN     2044   /* BLIT_MAP source span in texels (max(mapx)-min(mapx)+1) */

/* One texture page: 8 bpp indices + 256-entry palette of 0xAABBGGRR. */
typedef struct {
    const uint8_t *idx; int stride;       /* bytes per row */
    const uint32_t *pal;
    uint8_t levels[256]; int nlevels;     /* distinct palette alphas in 1..254 (for bm_alpha_word) */
} BmPage;
typedef struct { uint32_t *px; int stride; } BmSurf;   /* stride in pixels */

/* per-pixel datapath (exactly the hardware's) */
static inline uint32_t bm_div255(uint32_t x) { return (x + 1 + (x >> 8)) >> 8; }   /* exact for x <= 65534 (the datapath needs <= 65025) */
static inline uint32_t bm_tint(uint32_t px, uint32_t col, int fog) {
    if (fog) return (px & 0xFF000000u) | (col & 0xFFFFFFu);
    uint32_t r = bm_div255((px & 255) * (col & 255)), g = bm_div255(((px >> 8) & 255) * ((col >> 8) & 255)),
             b = bm_div255(((px >> 16) & 255) * ((col >> 16) & 255));
    return (px & 0xFF000000u) | r | (g << 8) | (b << 16);
}
static inline uint32_t bm_src_alpha(uint32_t ta, uint32_t aw) {
    if (!(aw & BM_ALT1)) return ta;
    if (ta == 255) return aw & 255;
    return (ta * (aw >> 16) + 0x8000u) >> 16;
}
static inline void bm_blend(uint32_t *d, uint32_t src, uint32_t sa, int mode) {
    uint32_t dc = *d;
    int sr = src & 255, sg = (src >> 8) & 255, sb = (src >> 16) & 255;
    int dr = dc & 255, dg = (dc >> 8) & 255, db = (dc >> 16) & 255, da = (dc >> 24) & 255;
    if (mode == 1) {
        dr += bm_div255(sr * sa); dg += bm_div255(sg * sa); db += bm_div255(sb * sa);
        if (dr > 255) dr = 255; if (dg > 255) dg = 255; if (db > 255) db = 255;
        if ((int)sa > da) da = sa;
    } else if (mode == 3) {
        dr -= bm_div255(sr * sa); dg -= bm_div255(sg * sa); db -= bm_div255(sb * sa);
        if (dr < 0) dr = 0; if (dg < 0) dg = 0; if (db < 0) db = 0;
    } else {
        dr = bm_div255(sr * sa + dr * (255 - sa)); dg = bm_div255(sg * sa + dg * (255 - sa));
        db = bm_div255(sb * sa + db * (255 - sa)); da = sa + bm_div255(da * (255 - sa));
    }
    *d = (uint32_t)dr | ((uint32_t)dg << 8) | ((uint32_t)db << 16) | ((uint32_t)da << 24);
}

/* CPU side: alpha word for a GML alpha. a16 is chosen so that every alpha level in
 * `levels` gives exactly the software result (uint)(level*alpha+0.5); returns the word,
 * *exact = 0 if no such a16 exists (then a16 = round(alpha*65536)). */
uint32_t bm_alpha_word(double alpha, const uint8_t *levels, int nlevels, int *exact);
/* build BmPage.levels from the palette */
void bm_page_levels(BmPage *pg);
/* RGBA page -> indices + palette (entry 0 = transparent). Returns colours used, -1 if > 256. */
int bm_index_page(const uint32_t *rgba, int w, int h, uint8_t *idx, uint32_t *pal);

/* Execute one drawing command (w[0..7], ops BLIT/FILL/CLEAR/BLIT_MAP).
 * dst->px points at the surface origin. For BLIT_MAP, mapx/mapy are the tables
 * (int32, -1 = skip), as read from w6/w7 by the hardware. */
void bm_exec(const uint32_t w[BM_CMD_WORDS], const BmPage *pg, BmSurf *dst, const int32_t *mapx, const int32_t *mapy);

/* Memory-image executor: runs a command stream exactly as the hardware does, with all
 * addresses (SET_DST/SET_TEX/palettes/tables) as byte offsets into `mem`. Used to make
 * HDL test vectors. Returns the last fence value. */
uint32_t bm_run_mem(uint8_t *mem, uint32_t memsize, const uint32_t *cmds, int ncmds);
#endif
