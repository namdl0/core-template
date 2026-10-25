#!/bin/sh
# Build and run the Verilator SoC simulation (UFO50 M3).
# Needs Verilator 5.x on PATH and the RISC-V toolchain for the -DSIM firmware.
# Usage (from the repo root): sh sim/verilator/run.sh [+max_ms=300]
set -e
cd "$(dirname "$0")/../.."
make -C firmware sim >/dev/null
mkdir -p sim/out
VERILATOR=${VERILATOR:-verilator}
$VERILATOR --cc --exe --build -j 2 -O3 --x-assign fast --x-initial fast --noassert \
    -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-PINCONNECTEMPTY -Wno-CASEINCOMPLETE -Wno-MULTIDRIVEN \
    -Wno-UNOPTFLAT -Wno-SELRANGE -Wno-BLKANDNBLK -Wno-COMBDLY -Wno-LATCH -Wno-TIMESCALEMOD \
    --top-module vl_top -Mdir sim/out/vl_obj \
    sim/verilator/vl_top.v src/fpga/core/ufo50_video.v src/fpga/core/soc/*.v src/fpga/core/periph/*.v src/fpga/core/cpu/VexRiscv.v \
    sim/verilator/tb_soc.cpp -CFLAGS "-O2" >sim/out/verilator_build.log 2>&1 || { tail -30 sim/out/verilator_build.log; exit 1; }
./sim/out/vl_obj/Vvl_top "$@"
