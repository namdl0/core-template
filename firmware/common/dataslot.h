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

/* Saves (nonvolatile slots): the APF reads SDRAM over the bridge.
 *   ds_write(id, off, src, n)   target command 0x0184: n bytes at src (SDRAM) -> offset off of the slot file
 *   ds_flush(id)                target command 0x0188: write the slot back to the card
 *   ds_table_set(id, size)      size-table entry of slot id (what the APF writes back on quit/sleep);
 *                               returns the table index used, <0 if the table is full
 *   ds_table_index(id)          table index of slot id or -1 */
int ds_write(uint16_t id, uint32_t offset, const void *src, uint32_t len);
int ds_flush(uint16_t id);
int ds_table_index(uint16_t id);
int ds_table_set(uint16_t id, uint32_t size);
#endif
