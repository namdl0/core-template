#!/bin/sh
# Blitter vs the bit-exact C model with random command streams, through the SoC port protocol
# (tb_blitter_soc.v + sdram_arb_model.v), Verilator 5 --timing. Usage: sh sim/periph/run_blit_vl.sh [workdir]
set -e
cd "$(dirname "$0")/../.."
W=${1:-sim/periph/work_vl}; mkdir -p $W
CC=${CC:-cc}
M=sim/periph/model
$CC -O2 -o $W/test_blit_unit $M/test_blit_unit.c $M/blit_model.c -lm
$W/test_blit_unit
$CC -O2 -o $W/blitgen $M/blitgen.c $M/blit_model.c -lm
SRC="src/fpga/core/soc/ufo50_blitter.v src/fpga/core/periph/blitter.v src/fpga/core/periph/blit_engine.v src/fpga/core/periph/periph_ram.v sim/periph/sdram_arb_model.v sim/periph/tb_blitter_soc.v"
VERILATOR=${VERILATOR:-verilator}
run() { # name gen-args params...
    n=$1; shift; g=$1; shift
    mkdir -p $W/$n; $W/blitgen $g $W/$n >/dev/null
    $VERILATOR --binary --timing -O2 -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-CASEINCOMPLETE -Wno-MULTIDRIVEN -Wno-BLKANDNBLK \
        -Wno-INITIALDLY -Wno-UNOPTFLAT -Wno-TIMESCALEMOD --top-module tb_blitter_soc -Mdir $W/$n/obj "$@" $SRC >$W/$n/build.log 2>&1 \
        || { tail -20 $W/$n/build.log; exit 1; }
    $W/$n/obj/Vtb_blitter_soc +mem=$W/$n/mem.bin +cmds=$W/$n/cmds.hex +out=$W/$n/out.hex $(cat $W/$n/args.txt) | grep -E "blitter_soc|ERROR"
    if cmp -s $W/$n/out.hex $W/$n/expect.hex; then echo "$n: PASS (HDL == C model)"; else echo "$n: FAIL"; exit 1; fi
}
run rnd_fast  "random 300 1" -GLAT=2
run rnd_stall "random 300 2" -GLAT=20 -GSTALL_PCT=30 -GGAP_PCT=30
run rnd_16bit "random 900 3" -GLAT=6 -GGAP_PCT=50
run rnd_gap   "random 600 4" -GLAT=3 -GSTALL_PCT=60 -GGAP_PCT=10
