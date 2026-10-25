/* link.ld - firmware in the 32 KB boot RAM at 0x00000000 (code, data, stack). */
OUTPUT_ARCH("riscv")
ENTRY(_start)
MEMORY { BRAM (rwx) : ORIGIN = 0x00000000, LENGTH = 32K }
STACK_SIZE = 4K;
SECTIONS
{
    .text : {
        KEEP(*(.text.start))
        *(.text .text.*)
    } > BRAM
    .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > BRAM
    .data : {
        *(.data .data.*)
        . = ALIGN(8);
        __global_pointer$ = . + 0x800;
        *(.sdata .sdata.*)
    } > BRAM
    .bss (NOLOAD) : {
        . = ALIGN(4);
        __bss_start = .;
        *(.sbss .sbss.* .bss .bss.* COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > BRAM
    . = ALIGN(16);
    __stack_bottom = .;
    __stack_top = ORIGIN(BRAM) + LENGTH(BRAM);
    ASSERT(__stack_top - __stack_bottom >= STACK_SIZE, "firmware too large for 32 KB boot RAM")
    /DISCARD/ : { *(.comment) *(.riscv.attributes) *(.note*) *(.eh_frame*) }
}
