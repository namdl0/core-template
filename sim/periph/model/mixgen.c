/* Test vectors for tb_mixer.v: sounds (IMA ADPCM / PCM16, mono / stereo, loops) in a memory
 * image, a random schedule of register writes, and the C model's output.
 *   mixgen <nsamples> <seed> <outdir>
 * Writes mem.bin (big-endian words), script.hex (count, then {sample index, key, data}
 * triples), expect.hex (one {R,L} word per sample).
 * Also self-checks the ADPCM codec (encoder/decoder round trip, SNR).
 * cc -O2 -o mixgen mixgen.c mixer_model.c adpcm.c -lm */
#include "mixer_model.h"
#include "adpcm.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

static uint64_t rs = 1;
static uint32_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return (uint32_t)rs; }
static uint32_t rr(uint32_t n) { return rnd() % n; }

#define MEMSZ (4u << 20)
static uint8_t mem[MEMSZ]; static uint32_t heap = 0x100;
static uint32_t alloc(uint32_t n) { uint32_t a = (heap + 63) & ~63u; heap = a + n; return a; }

typedef struct { uint32_t data, seek, len, loop; int adpcm, stereo; } Snd;
static Snd snd[8]; static int nsnd;

static void make_sound(long frames, int ch, int adpcm, uint32_t loop, int kind) {
    int16_t *pcm = malloc(2 * frames * ch);
    double ph = 0, f = 220 + rr(800);
    for (long i = 0; i < frames; i++) {
        ph += f / 44100.0 * 2 * M_PI; f *= kind ? 1.0002 : 1.0;
        for (int c = 0; c < ch; c++) {
            double s = 0.6 * sin(ph * (c ? 1.5 : 1.0)) + (kind == 2 ? ((int)rr(2001) - 1000) / 4000.0 : 0);
            if (i % 997 == 0) s = c ? -1.0 : 1.0;              /* full-scale clicks: clamp paths */
            pcm[i * ch + c] = (int16_t)(s > 1 ? 32767 : s < -1 ? -32768 : s * 32767);
        }
    }
    Snd *S = &snd[nsnd++]; S->len = (uint32_t)frames; S->loop = loop; S->adpcm = adpcm; S->stereo = ch == 2;
    if (adpcm) {
        long nb = ch == 1 ? (frames + 1) / 2 : frames, ns = ((frames + 255) / 256) * ch;
        S->data = alloc(nb + 8); S->seek = alloc(4 * ns);
        ima_encode(pcm, frames, ch, mem + S->data, (uint32_t *)(mem + S->seek));
        int16_t *dec = malloc(2 * frames * ch);
        ima_decode_stream(mem + S->data, (uint32_t *)(mem + S->seek), frames, ch, dec);
        double se = 0, ss = 0; for (long i = 0; i < frames * ch; i++) { double e = dec[i] - pcm[i]; se += e * e; ss += (double)pcm[i] * pcm[i]; }
        /* every seek-table entry must equal the decoder state at its block */
        int pred[2] = {0, 0}, idx[2] = {0, 0}, bad = 0;
        for (long fr = 0; fr < frames; fr++) for (int c = 0; c < ch; c++) {
            if (fr % 256 == 0) { uint32_t w = ((uint32_t *)(mem + S->seek))[(fr / 256) * ch + c]; bad += (int16_t)(w & 0xFFFF) != pred[c] || (int)((w >> 16) & 127) != idx[c]; }
            int n = ch == 1 ? (mem[S->data + (fr >> 1)] >> ((fr & 1) * 4)) & 15 : (mem[S->data + fr] >> (c * 4)) & 15;
            ima_decode(&pred[c], &idx[c], n);
        }
        printf("adpcm %s %ld frames: SNR %.1f dB, seek table %s\n", ch == 2 ? "stereo" : "mono", frames, 10 * log10(ss / (se + 1e-9)), bad ? "BAD" : "ok");
        free(dec);
    } else {
        S->data = alloc(2 * frames * ch + 8); memcpy(mem + S->data, pcm, 2 * frames * ch);
    }
    free(pcm);
}

typedef struct { uint32_t t, a, d; } Ev;
static Ev *ev; static int nev, cap;
static void at(uint32_t t, uint32_t a, uint32_t d) { if (nev == cap) { cap = cap ? 2 * cap : 1024; ev = realloc(ev, cap * sizeof *ev); } ev[nev++] = (Ev){t, a, d}; }
static int cmpev(const void *x, const void *y) { const Ev *a = x, *b = y; return a->t != b->t ? (a->t < b->t ? -1 : 1) : (a < b ? -1 : 1); }

static void start_voice(uint32_t t, int v) {
    Snd *S = &snd[rr(nsnd)];
    int loop = S->loop != 0xFFFFFFFF && rr(3) != 0;
    at(t, MX_REG_VOICE(v, MV_FORMAT), (S->adpcm ? MF_ADPCM : 0) | (S->stereo ? MF_STEREO : 0) | (loop ? MF_LOOP : 0) | (rr(4) ? MF_INTERP : 0) | rr(8) << 4);
    at(t, MX_REG_VOICE(v, MV_DATA), S->data); at(t, MX_REG_VOICE(v, MV_SEEK), S->seek);
    at(t, MX_REG_VOICE(v, MV_LENGTH), S->len); at(t, MX_REG_VOICE(v, MV_LOOP), loop ? S->loop : 0);
    at(t, MX_REG_VOICE(v, MV_START), rr(4) == 0 ? rr(S->len) : 0);
    static const uint32_t steps[] = {MX_STEP_44K1, MX_STEP_44K1, MX_STEP_44K1, 30106, 90317, 120422, 65536, 200000, 12345};
    at(t, MX_REG_VOICE(v, MV_STEP), steps[rr(9)]);
    at(t, MX_REG_VOICE(v, MV_GAIN), rr(3) ? 0x400 + rr(0x1400) : 0x1000);
    at(t, MX_REG_VOICE(v, MV_PAN), rr(2) ? 0x80008000u : (0x4000 + rr(0x8000)) | (0x4000 + rr(0x8000)) << 16);
    at(t, MX_REG_VOICE(v, MV_CTRL), MC_START);
}

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: mixgen <nsamples> <seed> <outdir>\n"); return 2; }
    int N = atoi(argv[1]); rs = strtoull(argv[2], 0, 0) * 2654435761u + 7; const char *dir = argv[3];
    make_sound(3000, 1, 1, 0xFFFFFFFF, 1);
    make_sound(2100, 2, 1, 700, 2);      /* loop start inside a block */
    make_sound(1500, 1, 0, 300, 0);
    make_sound(1000, 2, 0, 0, 2);
    make_sound(1800, 1, 1, 512, 0);      /* loop start on a block boundary */
    make_sound(600, 1, 1, 37, 2);
    /* schedule */
    for (int v = 0; v < 12; v++) start_voice(rr(50), v);
    for (uint32_t t = 50; t < (uint32_t)N; t += 1 + rr(40)) {
        int v = rr(MX_VOICES), r = rr(14);
        switch (r) {
        case 0: case 1: case 2: start_voice(t, v); break;
        case 3: at(t, MX_REG_VOICE(v, MV_CTRL), MC_STOP); break;
        case 4: at(t, MX_REG_VOICE(v, MV_CTRL), MC_PAUSE); at(t + 1 + rr(200), MX_REG_VOICE(v, MV_CTRL), MC_RESUME); break;
        case 5: at(t, MX_REG_VOICE(v, MV_FADE_TARGET), rr(0x5000)); at(t, MX_REG_VOICE(v, MV_FADE_LEN), rr(4) ? rr(3000) : 0); break;
        case 6: at(t, MX_REG_VOICE(v, MV_GAIN), rr(0x2000)); break;
        case 7: { int g = rr(MX_GROUPS); at(t, MX_REG_GROUP(g, 1), rr(0x5000)); at(t, MX_REG_GROUP(g, 2), rr(2000)); break; }
        case 8: at(t, MX_REG_GROUP(rr(MX_GROUPS), 0), rr(0x5000)); break;
        case 9: at(t, MX_REG_MASTER, 0x2000 + rr(0x5000)); break;
        case 10: at(t, MX_REG_VOICE(v, MV_STEP), 20000 + rr(150000)); break;
        case 11: at(t, MX_REG_VOICE(v, MV_START), rr(1000)); at(t, MX_REG_VOICE(v, MV_CTRL), MC_SEEK); break;
        case 12: at(t, MX_REG_VOICE(v, MV_PAN), rnd()); break;
        default: at(t, MX_REG_VOICE(v, MV_FADE_TARGET), 0x4000); at(t, MX_REG_VOICE(v, MV_FADE_LEN), 1 + rr(100)); break;
        }
    }
    if (argc > 4 && !strcmp(argv[4], "t0")) {   /* only the initial voice starts, all at sample 0 */
        int k = 0; for (int i = 0; i < nev; i++) if (ev[i].t < 50) { ev[k] = ev[i]; ev[k++].t = 0; } nev = k;
    }
    qsort(ev, nev, sizeof *ev, cmpev);
    int n = 0; while (n < nev && ev[n].t < (uint32_t)N) n++;
    /* model */
    static Mixer m; mx_reset(&m, mem);
    char p[512]; FILE *f;
    snprintf(p, sizeof p, "%s/expect.hex", dir); f = fopen(p, "w");
    long nz = 0; int e = 0; double rms = 0;
    for (int k = 0; k < N; k++) {
        while (e < n && ev[e].t == (uint32_t)k) { mx_write(&m, ev[e].a, ev[e].d); e++; }
        int16_t o[2]; mx_sample(&m, o);
        fprintf(f, "%04x%04x\n", (uint16_t)o[1], (uint16_t)o[0]);
        nz += o[0] != 0; rms += (double)o[0] * o[0];
    }
    fclose(f);
    snprintf(p, sizeof p, "%s/script.hex", dir); f = fopen(p, "w");
    fprintf(f, "%08x\n", n); for (int i = 0; i < n; i++) fprintf(f, "%08x\n%08x\n%08x\n", ev[i].t, (ev[i].a >> 2) & 0x7FF, ev[i].d); fclose(f);
    snprintf(p, sizeof p, "%s/mem.bin", dir); f = fopen(p, "wb");
    for (uint32_t i = 0; i < (heap + 3) / 4; i++) { uint8_t *b = mem + 4 * i; uint8_t be[4] = {b[3], b[2], b[1], b[0]}; fwrite(be, 1, 4, f); }
    fclose(f);
    printf("mixgen: %d samples, %d register writes, %ld non-zero left samples, rms %.0f, image %u KB\n", N, n, nz, sqrt(rms / N), heap >> 10);
    return 0;
}
