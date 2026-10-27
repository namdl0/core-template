/* Test-vector generator for tb_blitter.v.
 *   blitgen random <ncmds> <seed> <outdir>   random commands over random pages/palettes
 *   blitgen dump <dumpfile> <outdir> [maxseg] runtime display-list dump (ufo50rt --dl-dump)
 * Writes <outdir>/mem.bin (memory image, big-endian words for $fread), cmds.hex
 * (count + words), expect.hex (C-model result of the checked region) and args.txt
 * (plusargs for the region). For dumps it also checks the C model against the
 * rc_exec result recorded in the dump and reports mismatching pixels.
 * cc -O2 -o blitgen blitgen.c blit_model.c -lm */
#include "blit_model.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint64_t rs = 1;
static uint32_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return (uint32_t)rs; }
static uint32_t rr(uint32_t n) { return n ? rnd() % n : 0; }

#define MEMSZ (8u << 20)
static uint8_t *mem; static uint32_t heap = 0;
static uint32_t alloc(uint32_t n) { uint32_t a = (heap + 63) & ~63u; heap = a + n; if (heap > MEMSZ) { fprintf(stderr, "image too big\n"); exit(1); } return a; }
static uint32_t *cmd; static int ncmd, capcmd;
static void emit(const uint32_t w[8]) {
    if (ncmd + 8 > capcmd) { capcmd = capcmd ? capcmd * 2 : 4096; cmd = realloc(cmd, 4 * capcmd); }
    memcpy(cmd + ncmd, w, 32); ncmd += 8;
}
static void wr32(uint32_t a, uint32_t v) { memcpy(mem + a, &v, 4); }

static void write_out(const char *dir, uint32_t dbase, uint32_t dwords) {
    char p[512]; FILE *f;
    snprintf(p, sizeof p, "%s/mem.bin", dir); f = fopen(p, "wb");
    for (uint32_t i = 0; i < (heap + 3) / 4; i++) { uint8_t *b = mem + 4 * i; uint8_t be[4] = {b[3], b[2], b[1], b[0]}; fwrite(be, 1, 4, f); }
    fclose(f);
    snprintf(p, sizeof p, "%s/cmds.hex", dir); f = fopen(p, "w");
    fprintf(f, "%08x\n", ncmd); for (int i = 0; i < ncmd; i++) fprintf(f, "%08x\n", cmd[i]); fclose(f);
    uint8_t *m2 = malloc(MEMSZ); memcpy(m2, mem, MEMSZ);
    bm_run_mem(m2, MEMSZ, cmd, ncmd);
    snprintf(p, sizeof p, "%s/expect.hex", dir); f = fopen(p, "w");
    for (uint32_t i = 0; i < dwords; i++) { uint32_t v; memcpy(&v, m2 + 4 * (dbase + i), 4); fprintf(f, "%08x\n", v); }
    fclose(f); free(m2);
    snprintf(p, sizeof p, "%s/args.txt", dir); f = fopen(p, "w");
    fprintf(f, "+dbase=%x +dwords=%x\n", dbase, dwords); fclose(f);
}

/* ------------------------------------------------------------------ random mode */
static int gen_random(int n, const char *dir) {
    const int SW = 400, SH = 240, SSTR = 512 * 4;          /* surface with stride != width */
    uint32_t surf = alloc(SSTR * SH);
    for (uint32_t i = 0; i < (uint32_t)SSTR * SH / 4; i++) wr32(surf + 4 * i, rnd());
    enum { NP = 3, NPAL = 7 };
    int pw[NP] = {256, 300, 64}, ph[NP] = {128, 64, 64}, pst[NP] = {256, 304, 64};
    uint32_t page[NP], pal[NPAL]; BmPage pg[NPAL];
    for (int p = 0; p < NP; p++) { page[p] = alloc(pst[p] * ph[p]); for (int i = 0; i < pst[p] * ph[p]; i++) mem[page[p] + i] = (uint8_t)rnd(); }
    for (int q = 0; q < NPAL; q++) {
        pal[q] = alloc(1024);
        for (int i = 0; i < 256; i++) {
            uint32_t c = rnd(), a; int r = rr(10);
            a = r < 2 ? 0 : r < 7 ? 255 : (q % 2 ? (uint32_t)(1 + rr(254)) : (uint32_t)(64 * (1 + rr(3))));
            if (q == 5) a = r < 3 ? 0 : 255;           /* an opaque palette (no dst reads) */
            if (q == 6) a = i == 7 || i == 200 ? (uint32_t)(1 + rr(254)) : r < 3 ? 0 : 255;   /* 2 translucent entries: rows mixed */
            wr32(pal[q] + 4 * i, (c & 0xFFFFFF) | (a << 24));
        }
        pg[q].pal = (uint32_t *)(mem + pal[q]); bm_page_levels(&pg[q]);
    }
    static const double alphas[] = {1, 1, 1, 0.5, 0.3, 0.25, 0.1, 0.9, 0.75, 0.05, 0.999, 0.6, 2.0 / 3, 0};
    uint32_t w[8] = {0};
    w[0] = BM_SET_DST; w[1] = surf; w[2] = SSTR; emit(w);
    int cp = 0, cq = 0;
    for (int c = 0; c < n; c++) {
        memset(w, 0, sizeof w);
        if (c == 0 || rr(6) == 0) {
            cp = rr(NP); cq = rr(NPAL);
            w[0] = BM_SET_TEX | (rr(20) == 0 ? 1u << 10 : 0); w[1] = page[cp]; w[2] = pst[cp]; w[3] = pal[cq]; emit(w);
            memset(w, 0, sizeof w);
        }
        int op = (int[]){BM_BLIT, BM_BLIT, BM_BLIT, BM_BLIT_MAP, BM_BLIT_MAP, BM_FILL, BM_CLEAR}[rr(7)];
        int big = rr(8) == 0;
        int W = 1 + rr(big ? SW : 40), H = 1 + rr(big ? SH : 40);
        if (op == BM_BLIT) { if (W > pw[cp]) W = pw[cp]; if (H > ph[cp]) H = ph[cp]; }
        int dx = rr(SW - W + 1), dy = rr(SH - H + 1);
        int blend = (int[]){0, 0, 1, 3, 2}[rr(5)];
        double al = alphas[rr(sizeof alphas / sizeof *alphas)];
        w[0] = op | blend << 6 | (rr(2) ? BM_FLIPX : 0) | (rr(2) ? BM_FLIPY : 0) | (op != BM_FILL && rr(8) == 0 ? BM_FOG : 0);
        w[1] = dx | dy << 16; w[2] = W | H << 16;
        w[4] = op == BM_CLEAR ? rnd() : (rr(3) == 0 ? 0xFFFFFF : rnd() & 0xFFFFFF);
        w[5] = op == BM_CLEAR ? 0 : bm_alpha_word(al, op == BM_FILL ? NULL : pg[cq].levels, op == BM_FILL ? 0 : pg[cq].nlevels, NULL);
        if (op == BM_BLIT) { int sx = rr(pw[cp] - W + 1), sy = rr(ph[cp] - H + 1); w[3] = sx | sy << 16; }
        if (op == BM_BLIT_MAP) {
            int sx = rr(pw[cp] / 2), sy = rr(ph[cp] / 2), mw = pw[cp] - sx, mh = ph[cp] - sy;
            w[3] = sx | sy << 16;
            uint32_t tx = alloc(4 * W), ty = alloc(4 * H);
            int mode = rr(3);
            for (int i = 0; i < W; i++) wr32(tx + 4 * i, (uint32_t)(rr(10) == 0 ? -1 : mode == 0 ? (int)rr(mw) : (int)((i * mw) / W)));
            for (int j = 0; j < H; j++) wr32(ty + 4 * j, (uint32_t)(rr(10) == 0 ? -1 : mode == 1 ? (int)rr(mh) : (int)((j * mh) / H)));
            if (rr(15) == 0) for (int i = 0; i < W; i++) wr32(tx + 4 * i, 0xFFFFFFFFu);   /* all skipped */
            w[6] = tx; w[7] = ty;
        }
        emit(w);
        /* same-rectangle CLEAR chains (the hardware drops all but the last one) */
        if (op == BM_CLEAR && rr(3) == 0) { int k = 1 + rr(3); while (k--) { w[4] = rnd(); emit(w); } }
        if (op == BM_CLEAR && rr(4) == 0) { w[1] ^= 1; emit(w); }   /* a different rectangle right after */
    }
    memset(w, 0, sizeof w); w[0] = BM_FENCE | BM_IRQ; w[1] = 0xF00D0000u | (uint32_t)n; emit(w);
    write_out(dir, surf / 4, SSTR * SH / 4);
    printf("random: %d draw commands, %d words, image %u KB\n", n, ncmd, heap >> 10);
    return 0;
}

/* ------------------------------------------------------------------ dump mode
 * Dump format (little-endian, written by the runtime's --dl-dump, see BLITTER.md):
 *   'PAGE' u32 id, w, h, then 256 u32 palette, then w*h index bytes
 *   'SNAP' u32 surf, w, h, then w*h u32 pixels         (surface contents before a segment)
 *   'CMD ' u32 w[8] (hardware words, with page id in w[3] of SET_TEX), mapx[W], mapy[H] for BLIT_MAP
 *   'CHEK' u32 surf, w, h, then w*h u32 pixels         (rc_exec result at the end of a segment)
 *   'FRAM' u32 frame number */
typedef struct { int w, h; uint8_t *idx; uint32_t pal[256]; int used; int x0, y0, x1, y1; uint32_t addr, paladdr; } DPage;
static DPage *dp; static int ndp;
static uint32_t rd(FILE *f) { uint32_t v = 0; if (fread(&v, 4, 1, f) != 1) return 0xFFFFFFFFu; return v; }

static int gen_dump(const char *file, const char *dir, int maxseg, int skipseg) {
    FILE *f = fopen(file, "rb"); if (!f) { perror(file); return 1; }
    /* pass 1: pages + model-vs-rc_exec check on every segment, pick segments for HDL */
    long segs = 0, cmds_total = 0, bad_px = 0, px_total = 0, bad_seg = 0;
    uint32_t *surf = NULL; int sw = 0, sh = 0;
    long seg_start = -1;
    int chosen = 0; long chosen_pos[64]; int chosen_cnt = 0;
    BmPage cur; memset(&cur, 0, sizeof cur); int curp = -1;
    static int32_t mx[BM_MAX_W * 8], my[4096];
    char tag[5] = {0};
    long ncmd_seg = 0;
    while (fread(tag, 1, 4, f) == 4) {
        if (!memcmp(tag, "PAGE", 4)) {
            int id = rd(f), w = rd(f), h = rd(f);
            if (id >= ndp) { dp = realloc(dp, sizeof(DPage) * (id + 1)); memset(dp + ndp, 0, sizeof(DPage) * (id + 1 - ndp)); ndp = id + 1; }
            dp[id].w = w; dp[id].h = h; if (fread(dp[id].pal, 4, 256, f) != 256) return 1;
            dp[id].idx = malloc((size_t)w * h); if (fread(dp[id].idx, 1, (size_t)w * h, f) != (size_t)w * h) return 1;
            dp[id].x0 = w; dp[id].y0 = h; dp[id].x1 = dp[id].y1 = -1;
        } else if (!memcmp(tag, "FRAM", 4)) { rd(f); }
        else if (!memcmp(tag, "SNAP", 4)) {
            long pos = ftell(f) - 4;
            rd(f); sw = rd(f); sh = rd(f); surf = realloc(surf, 4 * (size_t)sw * sh);
            if (fread(surf, 4, (size_t)sw * sh, f) != (size_t)sw * sh) return 1;
            seg_start = pos; ncmd_seg = 0;
        } else if (!memcmp(tag, "CMD ", 4)) {
            uint32_t w[8]; for (int i = 0; i < 8; i++) w[i] = rd(f);
            int W = w[2] & 0xFFFF, H = w[2] >> 16;
            if (BM_OP(w[0]) == BM_BLIT_MAP) { if (fread(mx, 4, W, f) != (size_t)W || fread(my, 4, H, f) != (size_t)H) return 1; }
            if (BM_OP(w[0]) == BM_SET_TEX) { curp = w[3]; cur.idx = dp[curp].idx; cur.stride = dp[curp].w; cur.pal = dp[curp].pal; }
            else if (BM_OP(w[0]) <= BM_BLIT_MAP) {
                BmSurf s = {surf, sw};
                bm_exec(w, &cur, &s, mx, my); cmds_total++; ncmd_seg++;
                if (BM_OP(w[0]) == BM_BLIT || BM_OP(w[0]) == BM_BLIT_MAP) {   /* texel bounding box per page */
                    DPage *P = &dp[curp]; int sx = w[3] & 0xFFFF, sy = w[3] >> 16, x0, x1, y0, y1;
                    if (BM_OP(w[0]) == BM_BLIT) { x0 = sx; x1 = sx + W - 1; y0 = sy; y1 = sy + H - 1; }
                    else { x0 = 1 << 30; x1 = -1; y0 = 1 << 30; y1 = -1;
                        for (int i = 0; i < W; i++) if (mx[i] >= 0) { if (sx + mx[i] < x0) x0 = sx + mx[i]; if (sx + mx[i] > x1) x1 = sx + mx[i]; }
                        for (int j = 0; j < H; j++) if (my[j] >= 0) { if (sy + my[j] < y0) y0 = sy + my[j]; if (sy + my[j] > y1) y1 = sy + my[j]; } }
                    if (x1 >= 0 && y1 >= 0) { if (x0 < P->x0) P->x0 = x0; if (x1 > P->x1) P->x1 = x1; if (y0 < P->y0) P->y0 = y0; if (y1 > P->y1) P->y1 = y1; }
                }
            }
        } else if (!memcmp(tag, "CHEK", 4)) {
            rd(f); int w = rd(f), h = rd(f); uint32_t *ref = malloc(4 * (size_t)w * h);
            if (fread(ref, 4, (size_t)w * h, f) != (size_t)w * h) return 1;
            long b = 0; for (long i = 0; i < (long)w * h; i++) if (ref[i] != surf[i]) b++;
            bad_px += b; px_total += (long)w * h; bad_seg += b != 0; segs++;
            if (ncmd_seg > 0 && segs > skipseg && chosen < maxseg && chosen_cnt < 64) { chosen_pos[chosen_cnt++] = seg_start; chosen++; }
            free(ref);
        } else { fprintf(stderr, "bad tag %.4s at %ld\n", tag, ftell(f) - 4); return 1; }
    }
    printf("dump: %ld segments, %ld draw commands; C model vs rc_exec: %ld of %ld pixels differ, %ld segments differ\n",
           segs, cmds_total, bad_px, px_total, bad_seg);
    if (!dir) return bad_px != 0;
    /* pass 2: memory image of the chosen segments (each segment: own surface copy). Pages
     * are cropped to the texel bounding box used in the whole dump. */
    for (int i = 0; i < ndp; i++) if (dp[i].idx && dp[i].x1 >= 0) {
        DPage *P = &dp[i]; int cw = P->x1 - P->x0 + 1, ch = P->y1 - P->y0 + 1, st = (cw + 3) & ~3;
        P->addr = alloc(st * ch); P->paladdr = alloc(1024);
        for (int y = 0; y < ch; y++) memcpy(mem + P->addr + y * st, P->idx + (size_t)(P->y0 + y) * P->w + P->x0, cw);
        memcpy(mem + P->paladdr, P->pal, 1024);
        P->used = st;   /* cropped stride */
    }
    uint32_t region0 = 0, regionw = 0;
    for (int s = 0; s < chosen_cnt; s++) {
        fseek(f, chosen_pos[s] + 4, SEEK_SET);
        rd(f); sw = rd(f); sh = rd(f);
        uint32_t sa = alloc(4 * sw * sh); if (s == 0) region0 = sa;
        if (fread(mem + sa, 4, (size_t)sw * sh, f) != (size_t)sw * sh) return 1;
        regionw = (sa + 4 * sw * sh - region0) / 4;
        uint32_t w[8] = {BM_SET_DST, sa, (uint32_t)sw * 4, 0, 0, 0, 0, 0}; emit(w);
        while (fread(tag, 1, 4, f) == 4 && (!memcmp(tag, "CMD ", 4) || !memcmp(tag, "PAGE", 4))) {
            if (!memcmp(tag, "PAGE", 4)) { rd(f); int pw = rd(f), ph = rd(f); fseek(f, 1024 + (long)pw * ph, SEEK_CUR); continue; }
            for (int i = 0; i < 8; i++) w[i] = rd(f);
            int W = w[2] & 0xFFFF, H = w[2] >> 16;
            if (BM_OP(w[0]) == BM_SET_TEX) {
                DPage *P = &dp[w[3]]; curp = w[3];
                if (P->x1 < 0) continue;   /* page never drawn from */
                w[1] = P->addr; w[2] = P->used; w[3] = P->paladdr;
            } else if (BM_OP(w[0]) == BM_BLIT || BM_OP(w[0]) == BM_BLIT_MAP) {
                DPage *P = &dp[curp]; int sx = (w[3] & 0xFFFF) - P->x0, sy = (w[3] >> 16) - P->y0;
                if (BM_OP(w[0]) == BM_BLIT_MAP) {
                    if (fread(mx, 4, W, f) != (size_t)W || fread(my, 4, H, f) != (size_t)H) return 1;
                    /* re-base the tables on the crop: keep sx/sy relative, shift into range */
                    uint32_t tx = alloc(4 * W), ty = alloc(4 * H);
                    int ox = sx < 0 ? -sx : 0, oy = sy < 0 ? -sy : 0;
                    for (int i = 0; i < W; i++) wr32(tx + 4 * i, (uint32_t)(mx[i] < 0 ? -1 : mx[i] - ox));
                    for (int j = 0; j < H; j++) wr32(ty + 4 * j, (uint32_t)(my[j] < 0 ? -1 : my[j] - oy));
                    sx += ox; sy += oy; w[6] = tx; w[7] = ty;
                }
                w[3] = (uint32_t)sx | (uint32_t)sy << 16;
            } else if (BM_OP(w[0]) == BM_BLIT_MAP) {}
            emit(w);
        }
    }
    uint32_t w[8] = {BM_FENCE | BM_IRQ, 0xD0D0, 0, 0, 0, 0, 0, 0}; emit(w);
    write_out(dir, region0 / 4, regionw);
    printf("dump: %d segments into the HDL image (%d command words, image %u KB)\n", chosen_cnt, ncmd, heap >> 10);
    fclose(f);
    return bad_px != 0;
}

int main(int argc, char **argv) {
    mem = calloc(1, MEMSZ);
    if (argc >= 5 && !strcmp(argv[1], "random")) { rs = strtoull(argv[3], 0, 0) * 2654435761u + 1; return gen_random(atoi(argv[2]), argv[4]); }
    if (argc >= 3 && !strcmp(argv[1], "dump")) return gen_dump(argv[2], argc > 3 ? argv[3] : NULL, argc > 4 ? atoi(argv[4]) : 1, argc > 5 ? atoi(argv[5]) : 0);
    fprintf(stderr, "usage: blitgen random <n> <seed> <dir> | dump <file> [dir [nseg [skipseg]]]\n");
    return 2;
}
