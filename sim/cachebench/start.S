/* start.S - cache benchmark image header (slot-6 "U5RT" layout, docs/POCKET_RUNTIME.md in ufo50-ap). */
    .section .text.start, "ax"
    .globl _start
_start:
    j       entry
    .word   0x54523555          /* "U5RT" */
    .word   __image_end - _start
entry:
    .option push
    .option norelax
    la      gp, __global_pointer$
    .option pop
    li      sp, 0x13000000      /* stack in SDRAM (cached), like the runtime */
    li      t0, 0x6000
    csrs    mstatus, t0
    la      a0, __bss_start
    la      a1, __bss_end
1:  bgeu    a0, a1, 2f
    sw      zero, 0(a0)
    addi    a0, a0, 4
    j       1b
2:  call    main
3:  j       3b
