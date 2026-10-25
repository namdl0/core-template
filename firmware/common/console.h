/* console.h - 8x8 text console in the RGB565 framebuffers (48 x 27 characters). */
#ifndef CONSOLE_H
#define CONSOLE_H
#include <stdint.h>

#define CON_COLS 48
#define CON_ROWS 27

#define C_BLACK  0x0000
#define C_WHITE  0xFFFF
#define C_GREY   0x8410
#define C_RED    0xF800
#define C_GREEN  0x07E0
#define C_BLUE   0x001F
#define C_YELLOW 0xFFE0
#define C_CYAN   0x07FF
#define C_ORANGE 0xFC00
#define C_NAVY   0x0010

void con_init(uint16_t bg);                 /* clear both buffers, show buffer 0 */
void con_color(uint16_t fg, uint16_t bg);
void con_goto(int col, int row);
void con_putc(char c);                      /* draws into both buffers */
void con_puts(const char *s);
void con_hex(uint32_t v, int digits);
void con_dec(uint32_t v);
void con_dec64(uint64_t v);
void con_fixed(double v, int decimals);     /* double without printf */
void con_flush(void);                       /* no-op (write-through), kept for API symmetry */

/* draw into one buffer only (live area) */
void con_text_at(uint16_t *fb, int col, int row, const char *s, uint16_t fg, uint16_t bg);
void fb_fill_rect(uint16_t *fb, int x, int y, int w, int h, uint16_t c);
uint16_t *con_fb(int i);                    /* framebuffer i (0/1), cached window */

int  str_len(const char *s);
char *fmt_dec(char *p, uint32_t v);
char *fmt_hex(char *p, uint32_t v, int digits);
#endif
