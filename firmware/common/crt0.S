/* crt0.S - UFO50 Pocket SoC (M3) bare-metal startup. Reset vector 0x00000000 (boot RAM). */
    .section .text.start, "ax"
    .globl _start
_start:
    .option push
    .option norelax
    la      gp, __global_pointer$
    .option pop
    la      sp, __stack_top

    /* enable the FPU: mstatus.FS = Dirty, clear fcsr */
    li      t0, 0x6000
    csrs    mstatus, t0
    csrw    fcsr, zero

    la      t0, trap_entry
    csrw    mtvec, t0

    /* zero .bss (.data lives in boot RAM, loaded with the bitstream) */
    la      a0, __bss_start
    la      a1, __bss_end
1:  bgeu    a0, a1, 2f
    sw      zero, 0(a0)
    addi    a0, a0, 4
    j       1b
2:
    call    main
3:  j       3b

    /* any trap is fatal in M3: report mcause/mepc/mtval on screen */
    .balign 4
    .globl trap_entry
trap_entry:
    la      sp, __stack_top
    csrr    a0, mcause
    csrr    a1, mepc
    csrr    a2, mtval
    call    trap_handler
4:  j       4b
