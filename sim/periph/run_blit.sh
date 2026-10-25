#!/bin/sh
# Blitter: C-model unit tests + random HDL-vs-C-model runs (+ optional dump replay).
# Usage: sh sim/periph/run_blit.sh [workdir]   (IVERILOG/VVP on PATH)
set -e
cd "$(dirname "$0")/../.."
W=${1:-sim/periph/work}; mkdir -p $W
CC=${CC:-cc}
M=sim/periph/model
$CC -O2 -o $W/test_blit_unit $M/test_blit_unit.c $M/blit_model.c -lm
$W/test_blit_unit
$CC -O2 -o $W/blitgen $M/blitgen.c $M/blit_model.c -lm
SRC="src/fpga/core/periph/blitter.v src/fpga/core/periph/blit_engine.v src/fpga/core/periph/periph_ram.v src/fpga/core/periph/periph_mem_port.v sim/periph/sdram_model.v sim/periph/tb_blitter.v"
run() { # name gen-args iverilog-params
    n=$1; shift; g=$1; shift
    mkdir -p $W/$n; $W/blitgen $g $W/$n >/dev/null
    iverilog -g2012 -o $W/$n/tb.vvp "$@" $SRC
    vvp -n $W/$n/tb.vvp +mem=$W/$n/mem.bin +cmds=$W/$n/cmds.hex +out=$W/$n/out.hex $(cat $W/$n/args.txt) | grep blitter
    if cmp -s $W/$n/out.hex $W/$n/expect.hex; then echo "$n: PASS (HDL == C model)"; else echo "$n: FAIL"; exit 1; fi
}
run rnd_fast "random 300 1" -Ptb_blitter.LAT=6
run rnd_stall "random 300 2" -Ptb_blitter.LAT=20 -Ptb_blitter.STALL_PCT=30 -Ptb_blitter.GAP_PCT=30 -Ptb_blitter.MAX_BURST=16
run rnd_16bit "random 300 3" -Ptb_blitter.LAT=10 -Ptb_blitter.BEAT_CYC=2 -Ptb_blitter.MAX_BURST=8
