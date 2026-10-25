#include "mixer_model.h"
#include "adpcm.h"
#include <string.h>

#define M24 0xFFFFFFu
static uint32_t rd32(const uint8_t *m, uint32_t a) { uint32_t v; memcpy(&v, m + a, 4); return v; }
static uint32_t sat16u(uint32_t x) { return x > 0xFFFF ? 0xFFFF : x; }

void mx_reset(Mixer *m, const uint8_t *mem) {
    memset(m, 0, sizeof *m); m->mem = mem; m->master = MX_UNITY;
    for (int g = 0; g < MX_GROUPS; g++) m->g[g].gain = MX_UNITY << 8;
    for (int v = 0; v < MX_VOICES; v++) { m->v[v].panl = m->v[v].panr = MX_PAN1; m->v[v].step = 1u << 16; }
}

static void fade_start(uint32_t *gain, uint32_t target16, uint32_t n, uint32_t *gstep, uint8_t *fading, uint8_t *gup) {
    uint32_t t = target16 << 8;
    if (n == 0 || t == *gain) { *gain = t; *fading = 0; return; }
    uint32_t diff = t > *gain ? t - *gain : *gain - t;
    *gstep = diff / n; if (!*gstep) *gstep = 1;
    *gup = t > *gain; *fading = 1;
}
static void fade_step(uint32_t *gain, uint32_t target16, uint32_t gstep, uint8_t *fading, uint8_t gup) {
    if (!*fading) return;
    uint32_t t = target16 << 8;
    if (gup) { if (*gain >= t || t - *gain <= gstep) { *gain = t; *fading = 0; } else *gain += gstep; }
    else     { if (*gain <= t || *gain - t <= gstep) { *gain = t; *fading = 0; } else *gain -= gstep; }
}

static void apply(Mixer *m, uint32_t addr, uint32_t d) {
    uint32_t k = (addr >> 2) & 0x7FF;
    if (k == (MX_REG_MASTER >> 2)) { m->master = d & 0xFFFF; return; }
    if (k >= 0x200 && k < 0x220) {
        MxGroup *g = &m->g[(k >> 2) & 7];
        switch (k & 3) {
        case 0: g->gain = (d & 0xFFFF) << 8; g->fading = 0; break;
        case 1: g->target = d & 0xFFFF; break;
        case 2: fade_start(&g->gain, g->target, d & M24, &g->gstep, &g->fading, &g->gup); break;
        }
        return;
    }
    if (k < 0x400 || k >= 0x600) return;
    MxVoice *v = &m->v[(k >> 4) & 31];
    switch (k & 15) {
    case MV_CTRL:
        if (d & MC_START) { v->playing = 1; v->paused = 0; v->ended = 0; v->pos = v->start; v->frac = 0; v->seekp = 1; }
        if (d & MC_SEEK)  { v->pos = v->start; v->frac = 0; v->seekp = 1; }
        if (d & MC_STOP)  v->playing = 0;
        if (d & MC_PAUSE) v->paused = 1;
        if (d & MC_RESUME) v->paused = 0;
        break;
    case MV_FORMAT: v->fmt = d & 0x7F; break;
    case MV_DATA: v->base = d & 0x3FFFFFF; break;
    case MV_SEEK: v->hdr = d & 0x3FFFFFF; break;
    case MV_LENGTH: v->len = d & M24; break;
    case MV_LOOP: v->loop_start = d & M24; break;
    case MV_START: v->start = d & M24; break;
    case MV_STEP: v->step = d & 0xFFFFF; break;
    case MV_GAIN: v->gain = (d & 0xFFFF) << 8; v->fading = 0; break;
    case MV_FADE_TARGET: v->target = d & 0xFFFF; break;
    case MV_FADE_LEN: fade_start(&v->gain, v->target, d & M24, &v->gstep, &v->fading, &v->gup); break;
    case MV_PAN: v->panl = d & 0xFFFF; v->panr = d >> 16; break;
    }
}
void mx_write(Mixer *m, uint32_t addr, uint32_t data) {
    if (m->npend < 256) { m->pend_addr[m->npend] = addr; m->pend_data[m->npend++] = data; }
}
uint32_t mx_read(const Mixer *m, uint32_t addr) {
    uint32_t k = (addr >> 2) & 0x7FF;
    if (k < 0x400 || k >= 0x600) return 0;
    const MxVoice *v = &m->v[(k >> 4) & 31];
    if ((k & 15) == 0) return v->playing | v->paused << 1 | v->ended << 2;
    if ((k & 15) == 1) return v->pos;
    return 0;
}

static void reposition(Mixer *m, MxVoice *v, uint32_t p) {
    if (v->fmt & MF_ADPCM) {
        uint32_t blk = p >> 8, st = (v->fmt & MF_STEREO) ? 1 : 0;
        uint32_t a = (v->hdr + (blk << (2 + st))) & 0x3FFFFFF;
        uint32_t w = rd32(m->mem, a);
        v->predl = (int16_t)(w & 0xFFFF); v->idxl = (w >> 16) & 127;
        if (st) { w = rd32(m->mem, a + 4); v->predr = (int16_t)(w & 0xFFFF); v->idxr = (w >> 16) & 127; }
        v->dfr = blk << 8; v->skip = p & 255;
    } else { v->dfr = p; v->skip = 0; }
    v->dpos = (p - 1) & M24;
}
static void next(Mixer *m, MxVoice *v) {
    if (v->skip == 0 && ((v->dpos + 1) & M24) == v->len) {
        if (v->fmt & MF_LOOP) { reposition(m, v, v->loop_start); return; }
        v->al = v->bl; v->ar = v->br; v->dpos = v->len; return;
    }
    int st = !!(v->fmt & MF_STEREO), l, r;
    uint32_t f = v->dfr;
    if (v->fmt & MF_ADPCM) {
        uint32_t off = st ? f : f >> 1;
        uint8_t b = m->mem[(v->base + off) & 0x3FFFFFF];
        if (st) { l = ima_decode(&v->predl, &v->idxl, b & 15); r = ima_decode(&v->predr, &v->idxr, b >> 4); }
        else { l = r = ima_decode(&v->predl, &v->idxl, (f & 1) ? b >> 4 : b & 15); }
    } else {
        uint32_t a = (v->base + (st ? f << 2 : f << 1)) & 0x3FFFFFF;
        l = (int16_t)(m->mem[a] | m->mem[a + 1] << 8);
        r = st ? (int16_t)(m->mem[a + 2] | m->mem[a + 3] << 8) : l;
    }
    v->dfr = (v->dfr + 1) & M24;
    if (v->skip) { v->skip--; return; }
    v->al = v->bl; v->ar = v->br; v->bl = (int16_t)l; v->br = (int16_t)r; v->dpos = (v->dpos + 1) & M24;
}

void mx_sample(Mixer *m, int16_t out[2]) {
    for (int i = 0; i < m->npend; i++) apply(m, m->pend_addr[i], m->pend_data[i]);
    m->npend = 0;
    int32_t accl = 0, accr = 0;
    for (int vi = 0; vi < MX_VOICES; vi++) {
        MxVoice *v = &m->v[vi];
        if (!v->playing || v->paused) continue;
        if (v->pos >= v->len) {
            if (v->fmt & MF_LOOP) v->pos = (v->pos - (v->len - v->loop_start)) & M24;
            else { v->playing = 0; v->ended = 1; continue; }
        }
        if (v->seekp) { reposition(m, v, v->pos); v->al = v->ar = v->bl = v->br = 0; v->seekp = 0; }
        uint32_t target = ((v->pos + 1) & M24) == v->len ? ((v->fmt & MF_LOOP) ? v->loop_start : v->len) : (v->pos + 1) & M24;
        for (int guard = 0; v->dpos != target && guard < 4096; guard++) next(m, v);
        int32_t l = v->al, r = v->ar;
        if (v->fmt & MF_INTERP) {
            l += (int32_t)(((int64_t)(v->bl - v->al) * v->frac) >> 16);
            r += (int32_t)(((int64_t)(v->br - v->ar) * v->frac) >> 16);
        }
        uint32_t g1 = sat16u(((v->gain >> 8) * (m->g[(v->fmt >> 4) & 7].gain >> 8)) >> 14);
        uint32_t gl = sat16u((g1 * v->panl) >> 15), gr = sat16u((g1 * v->panr) >> 15);
        accl += (int32_t)(((int64_t)l * gl) >> 14); accr += (int32_t)(((int64_t)r * gr) >> 14);
        fade_step(&v->gain, v->target, v->gstep, &v->fading, v->gup);
        uint32_t fr = v->frac + (v->step & 0xFFFF);
        v->pos = (v->pos + (v->step >> 16) + (fr >> 16)) & M24; v->frac = fr & 0xFFFF;
    }
    for (int g = 0; g < MX_GROUPS; g++) fade_step(&m->g[g].gain, m->g[g].target, m->g[g].gstep, &m->g[g].fading, m->g[g].gup);
    int64_t ol = ((int64_t)accl * m->master) >> 14, orr = ((int64_t)accr * m->master) >> 14;
    out[0] = (int16_t)(ol > 32767 ? 32767 : ol < -32768 ? -32768 : ol);
    out[1] = (int16_t)(orr > 32767 ? 32767 : orr < -32768 ? -32768 : orr);
    m->samples++;
}
