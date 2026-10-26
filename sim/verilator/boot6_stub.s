# boot6_stub.s - minimal slot-6 runtime image for the bootloader test (tb_soc +boot6=).
# Layout per docs/POCKET_RUNTIME.md: +0 first instruction, +4 "U5RT", +8 image bytes.
# It only proves the loader validated the header and jumped here (code runs from SDRAM):
# it reports BENCH 01 0 (no mismatches) and BENCH ff (done) through DEBUG_OUT.
    .section .text
    .globl _start
_start:
    j       entry
    .word   0x54523555          # "U5RT"
    .word   image_end - _start
entry:
    lui     a0, %hi(0x80000FFC) # DEBUG_OUT
    addi    a0, a0, %lo(0x80000FFC)
    lui     a1, 0xBE010         # BENCH 01: 0 bad words
    sw      a1, 0(a0)
    lui     a1, 0xBEFF0         # BENCH ff: done
    sw      a1, 0(a0)
1:  j       1b
image_end:
