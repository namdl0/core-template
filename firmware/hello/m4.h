/* m4.h - M4 peripheral tests (blitter, mixer) and the ABGR8888 blitter demo. */
#ifndef M4_H
#define M4_H
#include <stdint.h>
int  blit_test(uint32_t clk, uint32_t *cycles, int *bad_px);
int  mix_test(uint32_t clk, uint32_t *rate_hz, uint32_t *blip_ms, uint32_t *underruns);
void blip(void);
/* runs until keep_going() returns 0; leaves VID_CTRL in ABGR8888 mode (caller restores) */
void m4_demo(uint32_t clk, int (*keep_going)(uint32_t frame, uint32_t keys));
#endif
