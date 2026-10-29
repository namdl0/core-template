/* align.S - the hello firmware's march write loop (6 instructions) at the 8 word offsets within a
 * 32-byte I$ line: store_loop_k(a0 = dst, a1 = words), k = 0..7 (cachebench results 21..28). */
    .section .text.align, "ax"
    .balign 64
.macro LOOP k
    .balign 32
    .globl store_loop_\k
store_loop_\k:
    j       1f
    .rept   \k
    nop
    .endr
1:  li      a3, 0
    li      a5, 0x12345
    j       3f
2:  sw      a2, 0(a0)
3:  add     a5, a5, a1
    addi    a3, a3, 1
    xor     a2, a5, a3
    addi    a0, a0, 4
    bne     a3, a1, 2b
    ret
.endm
LOOP 0
LOOP 1
LOOP 2
LOOP 3
LOOP 4
LOOP 5
LOOP 6
LOOP 7
