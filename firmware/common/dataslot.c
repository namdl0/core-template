/* dataslot.c - APF data slot access (see dataslot.h, docs/MEMORY_MAP.md 3.2) */
#include "dataslot.h"
#include "soc.h"

int ds_slot_size(uint16_t id, uint32_t *size)
{
    /* the APF table holds {id, size} pairs; unused entries read 0. A missing file and
     * an empty file both report 0 (not present). */
    for (int i = 0; i < 32; i++) {
        uint32_t sid = DS_TABLE(2 * i);
        uint32_t sz  = DS_TABLE(2 * i + 1);
        if ((sid & 0xFFFF) == id && sz != 0) { *size = sz; return 1; }
    }
    *size = 0;
    return 0;
}

int ds_busy(void) { return (DS_STATUS & DS_STATUS_BUSY) != 0; }

int ds_read_start(uint16_t id, uint32_t offset, void *dst, uint32_t len)
{
    uint32_t a = (uint32_t)(uintptr_t)dst & ~0x40000000u;   /* bridge address = cached window */
    if ((a >> 26) != (SDRAM_BASE >> 26)) return -8;
    while (ds_busy()) { }
    DS_SLOT_ID = id;
    DS_OFFSET  = offset;
    DS_ADDR    = a;
    DS_LENGTH  = len;
    DS_CMD     = 1;
    return 0;
}

int ds_result(void)
{
    uint32_t st = DS_STATUS;
    dcache_invalidate();
    if (st & DS_STATUS_ERR) return -(int)((st >> 8) & 7);
    return 0;
}

int ds_read(uint16_t id, uint32_t offset, void *dst, uint32_t len)
{
    uint8_t *d = (uint8_t *)dst;
    while (len) {
        uint32_t n = len > DS_CHUNK ? DS_CHUNK : len;
        int r = ds_read_start(id, offset, d, n);
        if (r) return r;
        while (ds_busy()) { }
        r = ds_result();
        if (r) return r;
        offset += n; d += n; len -= n;
    }
    return 0;
}
