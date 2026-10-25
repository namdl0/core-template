/*
 * soc.h - UFO50 Pocket SoC (M3) register map for C. Mirrors docs/MEMORY_MAP.md.
 */
#ifndef UFO50_SOC_H
#define UFO50_SOC_H

#include <stdint.h>

#define REG32(a) (*(volatile uint32_t *)(uintptr_t)(a))

/* memory */
#define BOOTRAM_BASE   0x00000000u
#define BOOTRAM_SIZE   (32u * 1024u)
#define SDRAM_BASE     0x10000000u          /* cached */
#define SDRAM_UC_BASE  0x50000000u          /* uncached alias */
#define SDRAM_SIZE     (64u * 1024u * 1024u)
#define UNCACHED(p)    ((void *)((uintptr_t)(p) | 0x40000000u))   /* 0x1xxxxxxx -> 0x5xxxxxxx */

/* default layout (firmware convention) */
#define SLOT0_ADDR     0x10000000u
#define SLOT1_ADDR     0x12800000u
#define SLOT4_ADDR     0x13000000u
#define HEAP_BASE      0x13100000u
#define FB0_ADDR       0x13F80000u
#define FB1_ADDR       0x13FC0000u

#define FB_W           384
#define FB_H           216
#define FB_STRIDE      768                   /* bytes */
#define RGB565(r, g, b) ((uint16_t)((((r) & 0xF8) << 8) | (((g) & 0xFC) << 3) | ((b) >> 3)))

/* system registers 0x8000_0000 */
#define SYS_BASE       0x80000000u
#define SYS_ID         REG32(SYS_BASE + 0x000)
#define SYS_VERSION    REG32(SYS_BASE + 0x004)
#define SYS_CLK_HZ     REG32(SYS_BASE + 0x008)
#define SYS_CONFIG     REG32(SYS_BASE + 0x00C)
#define MTIME_LO       REG32(SYS_BASE + 0x010)
#define MTIME_HI       REG32(SYS_BASE + 0x014)
#define MTIMECMP_LO    REG32(SYS_BASE + 0x018)
#define MTIMECMP_HI    REG32(SYS_BASE + 0x01C)
#define IRQ_PENDING    REG32(SYS_BASE + 0x020)
#define IRQ_ENABLE     REG32(SYS_BASE + 0x024)
#define CONT_KEY(n)    REG32(SYS_BASE + 0x030 + 12u * (n))
#define CONT_JOY(n)    REG32(SYS_BASE + 0x034 + 12u * (n))
#define CONT_TRIG(n)   REG32(SYS_BASE + 0x038 + 12u * (n))
#define CONT1_KEY      CONT_KEY(0)
#define RTC_EPOCH      REG32(SYS_BASE + 0x060)
#define RTC_VALID      REG32(SYS_BASE + 0x064)
#define OS_STATUS      REG32(SYS_BASE + 0x070)
#define VID_STATUS     REG32(SYS_BASE + 0x100)
#define VID_FRAME      REG32(SYS_BASE + 0x104)
#define FB_ADDR        REG32(SYS_BASE + 0x108)
#define FB_ACTIVE      REG32(SYS_BASE + 0x10C)
#define VID_CTRL       REG32(SYS_BASE + 0x110)
#define VID_BORDER     REG32(SYS_BASE + 0x114)
#define SDRAM_STATUS   REG32(SYS_BASE + 0x120)

#define IRQ_VBLANK     (1u << 0)
#define IRQ_SLOT       (1u << 1)
#define IRQ_BLIT       (1u << 2)
#define IRQ_AUDIO      (1u << 3)
#define IRQ_BUTTON     (1u << 4)

#define VID_STATUS_VBLANK     (1u << 0)
#define VID_STATUS_SWAP_PEND  (1u << 1)
#define VID_CTRL_SCANOUT      (1u << 0)
#define VID_CTRL_TESTPATTERN  (1u << 1)

/* cont_key bits */
#define KEY_UP     (1u << 0)
#define KEY_DOWN   (1u << 1)
#define KEY_LEFT   (1u << 2)
#define KEY_RIGHT  (1u << 3)
#define KEY_A      (1u << 4)
#define KEY_B      (1u << 5)
#define KEY_X      (1u << 6)
#define KEY_Y      (1u << 7)
#define KEY_L1     (1u << 8)
#define KEY_R1     (1u << 9)
#define KEY_L2     (1u << 10)
#define KEY_R2     (1u << 11)
#define KEY_L3     (1u << 12)
#define KEY_R3     (1u << 13)
#define KEY_SELECT (1u << 14)
#define KEY_START  (1u << 15)

/* data-slot controller 0x8001_0000 */
#define DS_BASE        0x80010000u
#define DS_SLOT_ID     REG32(DS_BASE + 0x00)
#define DS_OFFSET      REG32(DS_BASE + 0x04)
#define DS_ADDR        REG32(DS_BASE + 0x08)
#define DS_LENGTH      REG32(DS_BASE + 0x0C)
#define DS_CMD         REG32(DS_BASE + 0x10)
#define DS_STATUS      REG32(DS_BASE + 0x14)
#define DS_TABLE(i)    REG32(DS_BASE + 0x100 + 4u * (i))
#define DS_STATUS_BUSY (1u << 0)
#define DS_STATUS_DONE (1u << 1)
#define DS_STATUS_ERR  (1u << 2)

/* peripheral windows */
#define BLIT_BASE      0x80020000u
#define MIX_BASE       0x80030000u

/* cycle counter (rdcycle / rdcycleh), 64-bit safe */
static inline uint64_t rdcycle64(void)
{
    uint32_t hi, lo, hi2;
    do {
        __asm__ volatile ("rdcycleh %0" : "=r"(hi));
        __asm__ volatile ("rdcycle %0"  : "=r"(lo));
        __asm__ volatile ("rdcycleh %0" : "=r"(hi2));
    } while (hi != hi2);
    return ((uint64_t)hi << 32) | lo;
}
static inline uint32_t rdcycle(void) { uint32_t v; __asm__ volatile ("rdcycle %0" : "=r"(v)); return v; }
static inline uint32_t rdinstret(void) { uint32_t v; __asm__ volatile ("rdinstret %0" : "=r"(v)); return v; }

static inline uint64_t mtime64(void)
{
    uint32_t lo = MTIME_LO;          /* latches HI */
    return ((uint64_t)MTIME_HI << 32) | lo;
}

/* VexRiscv data cache: invalidate all lines (custom instruction, rs1 = x0).
 * Needed before reading SDRAM that hardware wrote (data slots, blitter) through
 * the cached window. The D$ is write-through, so nothing is lost. */
static inline void dcache_invalidate(void)
{
    __asm__ volatile (".word 0x0000500F" ::: "memory");
}
static inline void icache_invalidate(void) { __asm__ volatile ("fence.i" ::: "memory"); }

static inline uint32_t read_misa(void) { uint32_t v; __asm__ volatile ("csrr %0, misa" : "=r"(v)); return v; }

/* wait for the start of the next vertical blank */
static inline void wait_vblank(void)
{
    uint32_t f = VID_FRAME;
    while (VID_FRAME == f) { }
}

#endif
