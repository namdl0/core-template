/* console.c - text console for the UFO50 Pocket SoC M3 firmware */
#include "console.h"
#include "soc.h"
#include "font8x8.h"

static int cur_col, cur_row;
static uint16_t cur_fg = C_WHITE, cur_bg = C_BLACK;

uint16_t *con_fb(int i) { return (uint16_t *)(uintptr_t)(i ? FB1_ADDR : FB0_ADDR); }

void fb_fill_rect(uint16_t *fb, int x, int y, int w, int h, uint16_t c)
{
    for (int j = y; j < y + h; j++) {
        uint16_t *p = fb + j * FB_W + x;
        for (int i = 0; i < w; i++) p[i] = c;
    }
}

static void glyph(uint16_t *fb, int col, int row, char ch, uint16_t fg, uint16_t bg)
{
    if (ch < 0x20 || ch > 0x7E) ch = '?';
    const unsigned char *g = font8x8[ch - 0x20];
    uint32_t *p = (uint32_t *)(fb + row * 8 * FB_W + col * 8);
    for (int y = 0; y < 8; y++) {
        unsigned bits = g[y];
        for (int x = 0; x < 4; x++) {
            uint32_t lo = (bits & 1) ? fg : bg;
            uint32_t hi = (bits & 2) ? fg : bg;
            p[x] = lo | (hi << 16);
            bits >>= 2;
        }
        p += FB_W / 2;
    }
}

void con_init(uint16_t bg)
{
    uint32_t v = bg | ((uint32_t)bg << 16);
    for (int b = 0; b < 2; b++) {
        uint32_t *p = (uint32_t *)con_fb(b);
        for (int i = 0; i < FB_W * FB_H / 2; i++) p[i] = v;
    }
    cur_col = cur_row = 0;
    cur_bg = bg;
    FB_ADDR = FB0_ADDR;
    VID_CTRL = VID_CTRL_SCANOUT;
}

void con_color(uint16_t fg, uint16_t bg) { cur_fg = fg; cur_bg = bg; }
void con_goto(int col, int row) { cur_col = col; cur_row = row; }

void con_putc(char c)
{
    if (c == '\n') { cur_col = 0; cur_row++; }
    else {
        if (cur_col >= CON_COLS) { cur_col = 0; cur_row++; }
        if (cur_row >= CON_ROWS) cur_row = CON_ROWS - 1;   /* no scrolling: overwrite the last line */
        glyph(con_fb(0), cur_col, cur_row, c, cur_fg, cur_bg);
        glyph(con_fb(1), cur_col, cur_row, c, cur_fg, cur_bg);
        cur_col++;
    }
    if (cur_row >= CON_ROWS) cur_row = CON_ROWS - 1;
}

void con_puts(const char *s) { while (*s) con_putc(*s++); }

int str_len(const char *s) { int n = 0; while (s[n]) n++; return n; }

char *fmt_dec(char *p, uint32_t v)
{
    char t[11]; int n = 0;
    do { t[n++] = '0' + v % 10; v /= 10; } while (v);
    while (n) *p++ = t[--n];
    *p = 0;
    return p;
}

char *fmt_hex(char *p, uint32_t v, int digits)
{
    for (int i = digits - 1; i >= 0; i--) *p++ = "0123456789ABCDEF"[(v >> (i * 4)) & 15];
    *p = 0;
    return p;
}

void con_hex(uint32_t v, int digits) { char b[12]; fmt_hex(b, v, digits); con_puts(b); }
void con_dec(uint32_t v) { char b[12]; fmt_dec(b, v); con_puts(b); }

void con_dec64(uint64_t v)
{
    char t[21]; int n = 0;
    do { t[n++] = '0' + (char)(v % 10); v /= 10; } while (v);
    while (n) con_putc(t[--n]);
}

void con_fixed(double v, int decimals)
{
    if (v < 0) { con_putc('-'); v = -v; }
    double scale = 1.0;
    for (int i = 0; i < decimals; i++) scale *= 10.0;
    uint64_t q = (uint64_t)(v * scale + 0.5);
    uint64_t s = (uint64_t)scale;
    con_dec64(q / s);
    if (decimals) {
        con_putc('.');
        uint64_t f = q % s;
        char t[20];
        for (int i = decimals - 1; i >= 0; i--) { t[i] = '0' + (char)(f % 10); f /= 10; }
        for (int i = 0; i < decimals; i++) con_putc(t[i]);
    }
}

void con_flush(void) { }

void con_text_at(uint16_t *fb, int col, int row, const char *s, uint16_t fg, uint16_t bg)
{
    while (*s && col < CON_COLS) glyph(fb, col++, row, *s++, fg, bg);
}
