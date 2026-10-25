/* UFO50-IMA: IMA ADPCM as decoded by the mixer (src/fpga/core/periph/mix_core.v).
 * Format (docs/AUDIO_MIXER.md):
 *   data   : one nibble per channel per frame. Mono: 2 frames per byte, frame 2k in the
 *            low nibble of byte k, 2k+1 in the high nibble. Stereo: 1 byte per frame,
 *            left = low nibble, right = high nibble.
 *   seek   : one entry per 256 frames: per channel a little-endian u32
 *            [15:0] predictor (s16), [22:16] step index (0..88), [31:23] 0,
 *            the decoder state BEFORE frame 256*b. Stereo: left word then right word.
 *   decode : standard IMA (shift-add form), see ima_decode(). The stream is continuous;
 *            the seek table only allows starting at any frame. */
#ifndef ADPCM_H
#define ADPCM_H
#include <stdint.h>
#define IMA_BLOCK 256
extern const int16_t ima_step[89];
extern const int8_t ima_itab[8];
static inline int ima_decode(int *pred, int *idx, int n) {
    int step = ima_step[*idx], diff = step >> 3;
    if (n & 4) diff += step;
    if (n & 2) diff += step >> 1;
    if (n & 1) diff += step >> 2;
    int p = (n & 8) ? *pred - diff : *pred + diff;
    if (p > 32767) p = 32767; if (p < -32768) p = -32768;
    *pred = p;
    int i = *idx + ima_itab[n & 7]; if (i < 0) i = 0; if (i > 88) i = 88; *idx = i;
    return p;
}
/* Encode `frames` frames of `ch` (1/2) interleaved s16 channels. data: (ch==1 ? (frames+1)/2 : frames)
 * bytes; seek: ((frames+255)/256)*ch u32 words. Nibbles are chosen by exhaustive search
 * (minimum error) with the decoder in the loop. Returns bytes written. */
long ima_encode(const int16_t *pcm, long frames, int ch, uint8_t *data, uint32_t *seek);
/* Reference decoder of a whole stream (for tests). */
void ima_decode_stream(const uint8_t *data, const uint32_t *seek, long frames, int ch, int16_t *out);
#endif
