/*
 * m4.c - UFO50 Pocket SoC, milestone M4 tests: the real blitter and audio mixer.
 *
 *   blit_test()  : a command stream (SET_DST/SET_TEX/FILL/BLIT/flip/alpha/add/sub/fog/
 *                  BLIT_MAP/FENCE) run by the hardware, compared word for word with the
 *                  bit-exact C model (sim/periph/model/blit_model.c, bm_exec) on the CPU.
 *   mix_test()   : 48 kHz sample clock, a looping PCM16 tone (audible boot beep, then a
 *                  hardware fade-out) and a one-shot IMA ADPCM blip (encoded on the CPU with
 *                  the reference encoder), timed against the CPU clock.
 *   m4_demo()    : the blitter drawing every frame into a 32-bit ABGR8888 framebuffer
 *                  (VID_CTRL bit 2): scrolling tiles, sprites with flip/alpha/additive blend,
 *                  a BLIT_MAP-scaled sprite and text from a font page. A plays the ADPCM blip.
 *
 * Addresses given to the blitter/mixer are SDRAM byte offsets (they use address bits 25:0);
 * the CPU uses SDRAM_BASE + offset (cached, write-through) for the same memory.
 */
#include <stdint.h>
#include "soc.h"
#include "console.h"
#include "font8x8.h"
#include "../../sim/periph/model/blit_model.h"
#include "../../sim/periph/model/adpcm.h"
#include "m4.h"

#define BLT(r)      REG32(BLIT_BASE + (r))
#define MIX(r)      REG32(MIX_BASE + (r))
#define BLT_FIFO    REG32(BLIT_BASE + 0x8000)
#define CPU8(o)     ((uint8_t  *)(uintptr_t)(SDRAM_BASE + (o)))
#define CPU32(o)    ((uint32_t *)(uintptr_t)(SDRAM_BASE + (o)))
#define CPU16(o)    ((int16_t  *)(uintptr_t)(SDRAM_BASE + (o)))

/* SDRAM offsets (inside the heap region 0x0310_0000.., see docs/MEMORY_MAP.md) */
#define T_PAGE   0x03200000u    /* 64 x 32 test page, 8 bpp */
#define T_PAL    0x03210000u
#define T_MAPX   0x03211000u
#define T_MAPY   0x03212000u
#define T_DSTA   0x03300000u    /* 64 x 64 x 4 B, hardware */
#define T_DSTB   0x03320000u    /* same, C model */
#define F_PAGE   0x03230000u    /* font: 16 x 6 glyphs = 128 x 48 */
#define F_PAL    0x03238000u
#define S_PAGE   0x03240000u    /* sprites: 128 x 64 (UFO 64x64 | tiles 64x64) */
#define S_PAL    0x03250000u
#define D_MAPX   0x03251000u
#define D_MAPY   0x03252000u
#define FB32_0   0x03A00000u    /* demo framebuffers, 384 x 216 x 4 B = 331,776 B each */
#define FB32_1   0x03A80000u
#define A_TONE   0x03400000u    /* PCM16 tone */
#define A_BLIP   0x03500000u    /* ADPCM blip */
#define A_SEEK   0x03580000u

#define VID_CTRL_FMT32  (1u << 2)

#ifdef SIM
#define TONE_LEN   400          /* frames, 4 periods of 441 Hz */
#define BLIP_LEN   441          /* 10 ms */
#define MIX_WAIT_CYC (clk / 500) /* 2 ms */
#define BEEP_CYC   (clk / 500)
#else
#define TONE_LEN   4400
#define BLIP_LEN   4410         /* 100 ms */
#define MIX_WAIT_CYC (clk / 20)  /* 50 ms */
#define BEEP_CYC   (clk / 3)
#endif
#define STEP_44K1  60211u
#ifdef SIM
#define SIMDBG(tag, v) (REG32(SYS_BASE + 0xFFC) = ((uint32_t)(tag) << 20) | ((uint32_t)(v) & 0xFFFFF))   /* tb prints it */
#define BLIP_TIMEOUT (clk / 20)
#else
#define SIMDBG(tag, v) ((void)0)
#define BLIP_TIMEOUT clk
#endif

/* ----------------------------------------------------------------- blitter helpers */
static uint32_t cmds[8 * 16];
static int ncmd;

static void bl_push(const uint32_t *w)
{
    while ((BLT(0x04) >> 16) < 8) { }           /* STATUS[31:16] = FIFO words free */
    for (int i = 0; i < 8; i++) BLT_FIFO = w[i];
}
#ifdef SIM
static uint32_t *rec_list;          /* SIM: demo commands recorded for the model check */
static int rec_n;
#endif
static void bl(uint32_t w0, uint32_t w1, uint32_t w2, uint32_t w3, uint32_t w4, uint32_t w5, uint32_t w6, uint32_t w7)
{
    uint32_t w[8] = { w0, w1, w2, w3, w4, w5, w6, w7 };
#ifdef SIM
    if (rec_list) { for (int i = 0; i < 8; i++) rec_list[8 * rec_n + i] = w[i]; rec_n++; }
#endif
    bl_push(w);
}
static void rec(uint32_t w0, uint32_t w1, uint32_t w2, uint32_t w3, uint32_t w4, uint32_t w5, uint32_t w6, uint32_t w7)
{
    uint32_t *w = cmds + 8 * ncmd++;
    w[0] = w0; w[1] = w1; w[2] = w2; w[3] = w3; w[4] = w4; w[5] = w5; w[6] = w6; w[7] = w7;
}
#define XY(x, y)  ((uint32_t)(x) | ((uint32_t)(y) << 16))
#define A1        255u                                   /* alpha word for alpha == 1 */
#define AW(a255, a16) ((a255) | BM_ALT1 | ((uint32_t)(a16) << 16))

static int bl_wait_fence(uint32_t v, uint32_t timeout_cyc)
{
    uint32_t t0 = rdcycle();
    while (BLT(0x0C) != v) if (rdcycle() - t0 > timeout_cyc) return 0;
    while ((BLT(0x04) & 5) != 4) if (rdcycle() - t0 > timeout_cyc) return 0;   /* idle and FIFO empty */
    return 1;
}

/* the C model, run over a recorded stream with SDRAM as its memory (addresses = offsets) */
static void model_run_list(const uint32_t *list, int n, uint32_t dst_override)
{
    BmPage pg = { 0 };
    uint32_t dbase = 0, dstride = 0;
    for (int c = 0; c < n; c++) {
        const uint32_t *w = list + 8 * c;
        switch (BM_OP(w[0])) {
        case BM_SET_DST: dbase = dst_override; dstride = w[2] & 0xFFFF; break;
        case BM_SET_TEX: pg.idx = CPU8(w[1]); pg.stride = (int)(w[2] & 0xFFFF); pg.pal = CPU32(w[3]); break;
        case BM_BLIT: case BM_FILL: case BM_CLEAR: case BM_BLIT_MAP: {
            BmSurf s = { CPU32(dbase), (int)(dstride / 4) };
            bm_exec(w, &pg, &s, (const int32_t *)CPU32(w[6]), (const int32_t *)CPU32(w[7]));
            break;
        }
        default: break;
        }
    }
}
static void model_run(uint32_t dst_override) { model_run_list(cmds, ncmd, dst_override); }

int blit_test(uint32_t clk, uint32_t *cycles, int *bad_px)
{
    *cycles = 0; *bad_px = -1;
    if (BLT(0x00) != 0x424C5431u || !((SYS_CONFIG >> 25) & 1)) return 0;     /* "BLT1", present */
    BLT(0x08) = 4;                                                           /* soft reset */
    BLT(0x08) = 2;                                                           /* palette-cache flush */

    /* texture page: 64 x 32, a pattern over 16 indices; palette with opaque, translucent
       (alpha 96/160/200) and transparent entries */
    uint8_t *pg = CPU8(T_PAGE);
    for (int y = 0; y < 32; y++)
        for (int x = 0; x < 64; x++)
            pg[y * 64 + x] = (uint8_t)((((x >> 2) ^ (y >> 2)) + (x >> 4)) & 15);
    uint32_t *pal = CPU32(T_PAL);
    for (int i = 0; i < 256; i++) {
        uint32_t a = (i == 0) ? 0 : (i == 5) ? 96 : (i == 9) ? 160 : (i == 13) ? 200 : 255;
        pal[i] = (a << 24) | ((uint32_t)(i * 37 & 255) << 16) | ((uint32_t)(i * 71 & 255) << 8) | (uint32_t)(i * 13 & 255);
    }
    /* BLIT_MAP tables: 48 wide x 24 tall from the 64 x 32 page, a few skipped columns/rows */
    int32_t *mx = (int32_t *)CPU32(T_MAPX), *my = (int32_t *)CPU32(T_MAPY);
    for (int i = 0; i < 48; i++) mx[i] = (i % 11 == 10) ? -1 : (i * 64) / 48;
    for (int j = 0; j < 24; j++) my[j] = (j % 9 == 8) ? -1 : (j * 32) / 24;
    /* both destinations start with the same non-trivial content (blending reads it) */
    uint32_t *da = CPU32(T_DSTA), *db = CPU32(T_DSTB);
    for (int i = 0; i < 64 * 64; i++) da[i] = db[i] = 0x80000000u | (uint32_t)(i * 2654435761u >> 8);

    ncmd = 0;
    rec(BM_SET_DST, T_DSTA, 256, 0, 0, 0, 0, 0);
    rec(BM_SET_TEX | (1u << 10), T_PAGE, 64, T_PAL, 0, 0, 0, 0);
    rec(BM_FILL, XY(2, 2), XY(60, 20), 0, 0x336699, AW(191, 0xC000), 0, 0);              /* 75% fill */
    rec(BM_BLIT, XY(0, 10), XY(64, 32), 0, 0xFFFFFF, A1, 0, 0);                          /* plain */
    rec(BM_BLIT | BM_FLIPX, XY(8, 30), XY(40, 20), XY(10, 4), 0xC0FFA0, AW(128, 0x8000), 0, 0);  /* flip, tint, 50% */
    rec(BM_BLIT | BM_FLIPY | (1u << 6), XY(20, 0), XY(32, 32), XY(16, 0), 0xFFFFFF, A1, 0, 0);  /* flip Y, additive */
    rec(BM_BLIT | (3u << 6), XY(30, 40), XY(30, 20), XY(2, 6), 0x8080FF, A1, 0, 0);     /* subtract */
    rec(BM_BLIT | BM_FOG, XY(0, 50), XY(16, 12), XY(40, 0), 0x00FF00, AW(170, 0xAAAB), 0, 0);  /* fog */
    rec(BM_BLIT_MAP, XY(12, 36), XY(48, 24), 0, 0xFFFFFF, A1, T_MAPX, T_MAPY);           /* scaled */
    rec(BM_CLEAR, XY(60, 60), XY(4, 4), 0, 0x12345678, 0, 0, 0);
    rec(BM_FENCE, 0xB17E0001u, 0, 0, 0, 0, 0, 0);

    uint32_t b0 = BLT(0x14), t0 = rdcycle();
    for (int c = 0; c < ncmd; c++) bl_push(cmds + 8 * c);
    int ok = bl_wait_fence(0xB17E0001u, clk / 10);
    uint32_t t1 = rdcycle();
    *cycles = BLT(0x14) - b0;
    (void)t0; (void)t1;
    if (!ok) return 0;

    model_run(T_DSTB);
    dcache_invalidate();
    int bad = 0;
    for (int i = 0; i < 64 * 64; i++) bad += (da[i] != db[i]);
    *bad_px = bad;
    return bad == 0;
}

/* ----------------------------------------------------------------- mixer helpers */
#define MV(v, r)  MIX(0x1000 + 64 * (v) + 4 * (r))

static void gen_tone(int16_t *d, int n, double c, double s, double amp, double decay)
{
    double x = amp, y = 0.0;
    for (int i = 0; i < n; i++) {
        d[i] = (int16_t)y;
        double nx = x * c - y * s, ny = x * s + y * c;
        x = nx * decay; y = ny * decay;
    }
}

static void voice_start(int v, uint32_t fmt, uint32_t data, uint32_t seek, uint32_t len, uint32_t gain)
{
    MV(v, 1) = fmt;   MV(v, 2) = data; MV(v, 3) = seek; MV(v, 4) = len;
    MV(v, 5) = 0;     MV(v, 6) = 0;    MV(v, 7) = STEP_44K1;
    MV(v, 8) = gain;  MV(v, 11) = 0x80008000u;
    MV(v, 0) = 1;     /* start: all of the above apply together before the next sample */
}

void blip(void) { voice_start(1, 1u /* ADPCM, mono, one-shot */, A_BLIP, A_SEEK, BLIP_LEN, 0x3000); }

int mix_test(uint32_t clk, uint32_t *rate_hz, uint32_t *blip_ms, uint32_t *underruns)
{
    *rate_hz = 0; *blip_ms = 0; *underruns = 0;
    if (MIX(0x00) != 0x4D495831u || !((SYS_CONFIG >> 26) & 1)) return 0;   /* "MIX1", present */

    /* 441 Hz tone (100 samples/period at 44.1 kHz): cos/sin(2*pi/100) */
    gen_tone(CPU16(A_TONE), TONE_LEN, 0.99802672842827, 0.06279051952931, 9000.0, 1.0);
    /* 882 Hz decaying blip, IMA ADPCM via the reference encoder */
    int16_t *pcm = CPU16(A_TONE + 0x20000);
    gen_tone(pcm, BLIP_LEN, 0.99211470131448, 0.12533323356430, 20000.0, 0.99965);
    ima_encode(pcm, BLIP_LEN, 1, CPU8(A_BLIP), CPU32(A_SEEK));

    MIX(0x08) = 4;                    /* soft reset */
    MIX(0x08) = 1;                    /* enable */
    MIX(0x10) = 0x4000;               /* master unity */
    for (int g = 0; g < 8; g++) MIX(0x800 + 16 * g) = 0x4000;

    voice_start(0, (1u << 2) | (1u << 3), A_TONE, 0, TONE_LEN, 0x1800);    /* PCM16, loop, interpolate */
    uint64_t c0 = rdcycle64();
    while (rdcycle64() - c0 < clk / 1000) { }                              /* let the FIFO fill */
    uint32_t s0 = MIX(0x0C), u0 = MIX(0x14), p0 = MV(0, 1);
    c0 = rdcycle64();
    while (rdcycle64() - c0 < MIX_WAIT_CYC) { }
    uint32_t s1 = MIX(0x0C), u1 = MIX(0x14), p1 = MV(0, 1), st = MV(0, 0);
    SIMDBG(0x101, s1 - s0); SIMDBG(0x102, u1 - u0); SIMDBG(0x103, st); SIMDBG(0x104, p1 - p0);
    uint64_t c1 = rdcycle64();
    *rate_hz = (uint32_t)((double)(s1 - s0) * (double)clk / (double)(c1 - c0) + 0.5);
    int ok = (*rate_hz > 47000 && *rate_hz < 49000) && (st & 1) && p1 != p0;

    /* audible boot beep, then a hardware fade-out over 100 ms */
    while (rdcycle64() - c0 < BEEP_CYC) { }
    MV(0, 9) = 0; MV(0, 10) = 4800;

    /* ADPCM one-shot: must end on its own after ~100 ms (10 ms in SIM) */
    blip();
    c0 = rdcycle64();
    while (!(MV(1, 0) & 4) && rdcycle64() - c0 < BLIP_TIMEOUT) { }
    SIMDBG(0x105, MV(1, 0)); SIMDBG(0x106, MV(1, 1));
    c1 = rdcycle64();
    *blip_ms = (uint32_t)((c1 - c0) * 1000 / clk);
    uint32_t want = BLIP_LEN * 1000u / 44100u;
    ok = ok && (MV(1, 0) & 4) && *blip_ms + 3 >= want && *blip_ms <= want + 6;
    *underruns = MIX(0x14) - u0;
    ok = ok && (u1 == u0);
    MV(0, 0) = 2;                     /* stop the (silent) tone */
    return ok;
}

/* ----------------------------------------------------------------- demo (ABGR8888) */
static void build_pages(void)
{
    /* font page: glyph c at (16 x (c % 16) ... ), index 1 = ink */
    uint8_t *f = CPU8(F_PAGE);
    for (int g = 0; g < 96; g++)
        for (int y = 0; y < 8; y++)
            for (int x = 0; x < 8; x++)
                f[((g / 16) * 8 + y) * 128 + (g % 16) * 8 + x] = (g < 95) ? (font8x8[g][y] >> x) & 1 : 0;
    uint32_t *fp = CPU32(F_PAL);
    for (int i = 0; i < 256; i++) fp[i] = (i == 1) ? 0xFFFFFFFFu : 0;

    /* sprite page: a saucer (left 64x64) and a 32-px-periodic tile pattern (right 64x64) */
    uint8_t *s = CPU8(S_PAGE);
    for (int y = 0; y < 64; y++)
        for (int x = 0; x < 128; x++) {
            uint8_t v = 0;
            if (x < 64) {
                int dx = x - 32, dy = y - 38;
                if (dx * dx * 4 + dy * dy * 36 < 30 * 30 * 4) v = (uint8_t)(1 + ((dy + 8) * 7 / 16 > 7 ? 7 : (dy + 8) * 7 / 16 < 0 ? 0 : (dy + 8) * 7 / 16));
                int ey = y - 30;
                if (!v && dx * dx + ey * ey * 2 < 14 * 14 && ey < 2) v = 9;                  /* translucent dome */
                if ((y == 40) && ((x / 6) % 2) && dx * dx < 24 * 24) v = 14;                 /* lights */
            } else {
                int tx = (x - 64) & 31, ty = y & 31;
                v = (uint8_t)(10 + (((tx >> 4) ^ (ty >> 4)) & 1) * 2 + ((tx & 15) == 0 || (ty & 15) == 0));
            }
            s[y * 128 + x] = v;
        }
    uint32_t *sp = CPU32(S_PAL);
    for (int i = 0; i < 256; i++) sp[i] = 0;
    for (int i = 1; i <= 8; i++) { uint32_t g = 90 + i * 18; sp[i] = 0xFF000000u | (g + 30 > 255 ? 255 : g + 30) << 16 | g << 8 | (g - 40); }
    sp[9] = 0xA0FFE070u;                                  /* dome: alpha 160, cyan */
    sp[10] = 0xFF503018u; sp[11] = 0xFF281808u; sp[12] = 0xFF604020u; sp[13] = 0xFF301C0Cu;
    sp[14] = 0xFF40F0FFu;                                 /* yellow lights */
}

static void text(int x, int y, const char *str, uint32_t tint)
{
    for (; *str && x + 8 <= 384; str++, x += 8) {   /* clip: past x=384 a blit would wrap to the next line */
        int g = *str - 32;
        if (g <= 0 || g >= 95) continue;
        bl(BM_BLIT, XY(x, y), XY(8, 8), XY((g % 16) * 8, (g / 16) * 8), tint, A1, 0, 0);
    }
}

void m4_demo(uint32_t clk, int (*keep_going)(uint32_t frame, uint32_t keys))
{
    build_pages();
    struct { int x, y, vx, vy; } u[6];
    for (int i = 0; i < 6; i++) { u[i].x = 20 + i * 50; u[i].y = 10 + i * 23; u[i].vx = (i & 1) ? -2 : 2 + i % 3; u[i].vy = (i & 2) ? -1 : 1 + i % 2; }

    int back = 1;
    uint32_t frame = 0, busy_last = 0, wait_last = 0, keys_prev = CONT1_KEY;
    for (;;) {
        uint32_t keys = CONT1_KEY;
        if (!keep_going(frame, keys)) break;
        if ((keys & ~keys_prev) & KEY_A) blip();
        keys_prev = keys;

        uint32_t fb = back ? FB32_1 : FB32_0, b0 = BLT(0x14), w0 = BLT(0x1C), n = 0;
#ifdef SIM
        rec_list = CPU32(0x03600000u); rec_n = 0;
        uint32_t mw0 = BLT(0x1C);
#endif
        bl(BM_SET_DST, fb, 1536, 0, 0, 0, 0, 0);
        bl(BM_SET_TEX, S_PAGE, 128, S_PAL, 0, 0, 0, 0);
        /* scrolling tiles, 24 x 13 cells of 16 x 16 + a bottom strip of 8 */
        uint32_t sx = 64 + (frame & 31), sy = (frame >> 1) & 31;
        for (int ty = 0; ty < 14; ty++)
            for (int tx = 0; tx < 24; tx++, n++)
                bl(BM_BLIT, XY(tx * 16, ty * 16), XY(16, ty == 13 ? 8 : 16), XY(sx, sy), 0xFFFFFF, A1, 0, 0);
        /* saucers: normal, flipped, 50% alpha, additive */
        for (int i = 0; i < 6; i++, n++) {
            u[i].x += u[i].vx; u[i].y += u[i].vy;
            if (u[i].x < 0) { u[i].x = 0; u[i].vx = -u[i].vx; }
            if (u[i].x > 384 - 64) { u[i].x = 384 - 64; u[i].vx = -u[i].vx; }
            if (u[i].y < 16) { u[i].y = 16; u[i].vy = -u[i].vy; }
            if (u[i].y > 216 - 64) { u[i].y = 216 - 64; u[i].vy = -u[i].vy; }
            uint32_t op = BM_BLIT | (u[i].vx < 0 ? BM_FLIPX : 0) | (i == 4 ? (1u << 6) : 0);
            bl(op, XY(u[i].x, u[i].y), XY(64, 64), 0, (keys & KEY_B) ? 0x8080FF : 0xFFFFFF, i == 3 ? AW(128, 0x8000) : A1, 0, 0);
        }
        /* BLIT_MAP: a saucer pulsing between 32 and 120 px */
        int ph = (int)(frame % 120), sz = 32 + (ph < 60 ? ph : 120 - ph) * 88 / 60;
        int32_t *mxp = (int32_t *)CPU32(D_MAPX), *myp = (int32_t *)CPU32(D_MAPY);
        for (int i = 0; i < sz; i++) { mxp[i] = i * 64 / sz; myp[i] = i * 64 / sz; }
        bl(BM_BLIT_MAP, XY(384 - 8 - sz, 216 - 8 - sz), XY(sz, sz), 0, 0xFFFFFF, A1, D_MAPX, D_MAPY); n++;
        /* text */
        bl(BM_SET_TEX, F_PAGE, 128, F_PAL, 0, 0, 0, 0);
        bl(BM_FILL, XY(0, 0), XY(384, 16), 0, 0x000000, AW(160, 0xA0A1), 0, 0);
        text(4, 0, "M4 BLITTER+MIXER   A: blip  B: tint  SE: back", 0x60FFFF);
        char b[64], *p = b;
        const char *s = "blit "; while (*s) *p++ = *s++;
        p = fmt_dec(p, busy_last / 1000); s = "k cyc  wait "; while (*s) *p++ = *s++;
        p = fmt_dec(p, wait_last / 1000); s = "k  mix "; while (*s) *p++ = *s++;
        p = fmt_dec(p, MIX(0x18) >> 16); s = "  und "; while (*s) *p++ = *s++;
        p = fmt_dec(p, MIX(0x14)); *p = 0;
        text(4, 8, b, 0xFFFFFF);
        bl(BM_FENCE, frame + 1, 0, 0, 0, 0, 0, 0);

        bl_wait_fence(frame + 1, clk);
        busy_last = BLT(0x14) - b0;
        wait_last = BLT(0x1C) - w0;
#ifdef SIM
        if (frame == 1 || frame == 2) {
            uint32_t mw = BLT(0x1C) - mw0;
            rec_list = 0;
            model_run_list(CPU32(0x03600000u), rec_n, 0x03B00000u);
            dcache_invalidate();
            const uint32_t *hw = CPU32(fb), *md = CPU32(0x03B00000u);
            uint32_t bad = 0, first = 0xFFFFF;
            for (int i = 0; i < 384 * 216; i++) if (hw[i] != md[i]) { if (!bad) first = (uint32_t)i; bad++; }
            SIMDBG(0x1A0, bad); SIMDBG(0x1A1, first % 384); SIMDBG(0x1A2, first / 384);
            SIMDBG(0x1A3, busy_last >> 4); SIMDBG(0x1A4, mw >> 4); SIMDBG(0x1A5, rec_n);
            if (bad) { SIMDBG(0x1A6, hw[first] >> 12); SIMDBG(0x1A7, md[first] >> 12); }
        }
#endif
        FB_ADDR = SDRAM_BASE + fb;
        VID_CTRL = VID_CTRL_SCANOUT | VID_CTRL_FMT32;
        while (VID_STATUS & VID_STATUS_SWAP_PEND) { }
        back ^= 1;
        frame++;
        REG32(SYS_BASE + 0xFFC) = 0x00010000u | (frame & 0xFFFF);   /* simulation marker */
    }
}
