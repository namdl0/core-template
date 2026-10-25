/* Bit-exact, cycle-free C model of the UFO 50 audio mixer (src/fpga/core/periph/mix_*.v).
 * Register map and semantics: docs/AUDIO_MIXER.md. */
#ifndef MIXER_MODEL_H
#define MIXER_MODEL_H
#include <stdint.h>

#define MX_VOICES 32
#define MX_GROUPS 8
/* register byte offsets in the 64 KB window (writes go through the command FIFO) */
#define MX_REG_MASTER        0x0010
#define MX_REG_GROUP(g, r)   (0x0800 + (g) * 16 + (r) * 4)    /* r: 0 GAIN, 1 FADE_TARGET, 2 FADE_LEN */
#define MX_REG_VOICE(v, r)   (0x1000 + (v) * 64 + (r) * 4)
enum { MV_CTRL, MV_FORMAT, MV_DATA, MV_SEEK, MV_LENGTH, MV_LOOP, MV_START, MV_STEP,
       MV_GAIN, MV_FADE_TARGET, MV_FADE_LEN, MV_PAN };
enum { MC_START = 1, MC_STOP = 2, MC_PAUSE = 4, MC_RESUME = 8, MC_SEEK = 16 };
enum { MF_ADPCM = 1, MF_STEREO = 2, MF_LOOP = 4, MF_INTERP = 8 };   /* [6:4] group */
#define MX_UNITY  0x4000u     /* gains: Q2.14 */
#define MX_PAN1   0x8000u     /* pan: Q1.15 */
#define MX_STEP_44K1 60211u   /* 44100/48000 in u4.16 */

typedef struct {
    uint32_t base, hdr, len, loop_start, start, step, panl, panr, gain, target, gstep;
    uint8_t fading, gup, fmt;
    uint32_t pos, frac, dpos, dfr; uint8_t skip, playing, paused, seekp, ended;
    int16_t al, ar, bl, br; int predl, idxl, predr, idxr;
} MxVoice;
typedef struct { uint32_t gain, target, gstep; uint8_t fading, gup; } MxGroup;
typedef struct {
    MxVoice v[MX_VOICES]; MxGroup g[MX_GROUPS]; uint32_t master;
    const uint8_t *mem;              /* sample memory, byte addresses as the hardware sees them */
    uint32_t pend_addr[256], pend_data[256]; int npend;
    uint32_t samples;
} Mixer;

void mx_reset(Mixer *m, const uint8_t *mem);
void mx_write(Mixer *m, uint32_t addr, uint32_t data);   /* queued; applied before the next sample */
void mx_sample(Mixer *m, int16_t out[2]);
uint32_t mx_read(const Mixer *m, uint32_t addr);         /* voice status/position readback */
#endif
