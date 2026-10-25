#include "adpcm.h"
#include <string.h>
#include <stdlib.h>

const int16_t ima_step[89] = {
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97,
    107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
    876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871,
    5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623,
    27086, 29794, 32767};
const int8_t ima_itab[8] = {-1, -1, -1, -1, 2, 4, 6, 8};

long ima_encode(const int16_t *pcm, long frames, int ch, uint8_t *data, uint32_t *seek) {
    int pred[2] = {0, 0}, idx[2] = {0, 0};
    long nbytes = ch == 1 ? (frames + 1) / 2 : frames;
    memset(data, 0, nbytes);
    for (long f = 0; f < frames; f++) {
        if (f % IMA_BLOCK == 0)
            for (int c = 0; c < ch; c++)
                seek[(f / IMA_BLOCK) * ch + c] = (uint16_t)pred[c] | (uint32_t)idx[c] << 16;
        for (int c = 0; c < ch; c++) {
            int target = pcm[f * ch + c], best = 0; long berr = -1;
            for (int n = 0; n < 16; n++) {
                int p = pred[c], i = idx[c]; ima_decode(&p, &i, n);
                long e = labs((long)p - target);
                if (berr < 0 || e < berr) { berr = e; best = n; }
            }
            ima_decode(&pred[c], &idx[c], best);
            if (ch == 1) data[f >> 1] |= (uint8_t)(best << ((f & 1) * 4));
            else data[f] |= (uint8_t)(best << (c * 4));
        }
    }
    return nbytes;
}

void ima_decode_stream(const uint8_t *data, const uint32_t *seek, long frames, int ch, int16_t *out) {
    int pred[2], idx[2];
    for (int c = 0; c < ch; c++) { pred[c] = (int16_t)(seek[c] & 0xFFFF); idx[c] = (seek[c] >> 16) & 127; }
    for (long f = 0; f < frames; f++)
        for (int c = 0; c < ch; c++) {
            int n = ch == 1 ? (data[f >> 1] >> ((f & 1) * 4)) & 15 : (data[f] >> (c * 4)) & 15;
            out[f * ch + c] = (int16_t)ima_decode(&pred[c], &idx[c], n);
        }
}
