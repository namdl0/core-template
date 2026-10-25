/* dataslot.h - C driver for APF data slots (target command 0x0180), UFO50 Pocket SoC.
 *
 *   ds_slot_size(id, &size)   size of the file in slot <id> from the APF size table
 *   ds_read(id, off, dst, n)  APF copies n bytes at offset off of slot id to dst (SDRAM),
 *                             blocks until done, invalidates the D$. 0 = ok, <0 = -APF error.
 *
 * dst must be in SDRAM (0x1xxxxxxx or the uncached alias 0x5xxxxxxx), 4-byte aligned;
 * use multiples of 4 for n and off. Large reads are split into DS_CHUNK pieces.
 */
#ifndef DATASLOT_H
#define DATASLOT_H
#include <stdint.h>

#define DS_CHUNK (1u << 20)

int ds_slot_size(uint16_t id, uint32_t *size);
int ds_read(uint16_t id, uint32_t offset, void *dst, uint32_t len);
int ds_read_start(uint16_t id, uint32_t offset, void *dst, uint32_t len);  /* non-blocking */
int ds_busy(void);
int ds_result(void);        /* after !ds_busy(): 0 ok, <0 error; invalidates the D$ */
#endif
