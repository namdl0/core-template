/* cachebench image: loaded by the APF to the slot-6 address and run from SDRAM. */
OUTPUT_ARCH("riscv")
ENTRY(_start)
MEMORY { SD (rwx) : ORIGIN = 0x12880000, LENGTH = 1M }
SECTIONS
{
    .text : { KEEP(*(.text.start)) *(.text .text.*) } > SD
    .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > SD
    .data : { *(.data .data.*) . = ALIGN(8); __global_pointer$ = . + 0x800; *(.sdata .sdata.*) . = ALIGN(16); } > SD
    __image_end = .;
    .bss (NOLOAD) : { . = ALIGN(4); __bss_start = .; *(.sbss .sbss.* .bss .bss.* COMMON) . = ALIGN(4); __bss_end = .; } > SD
    /DISCARD/ : { *(.comment) *(.riscv.attributes) *(.note*) *(.eh_frame*) }
}
