#!/bin/sh
# Simulate the M1 video timing/test pattern with Icarus Verilog (>= 11).
# Usage (from the repo root):  sh sim/run_sim.sh
# Writes sim/frame1.ppm (normal) and sim/frame3.ppm (A held).
set -e
cd "$(dirname "$0")/.."
IVERILOG=${IVERILOG:-iverilog}
VVP=${VVP:-vvp}
$IVERILOG -g2005 -Wall -o sim/tb.vvp sim/tb_ufo50_video.v src/fpga/core/ufo50_video.v
$VVP -n sim/tb.vvp
$IVERILOG -g2005 -Wall -o sim/tb_box.vvp sim/tb_box_bounce.v src/fpga/core/ufo50_video.v
$VVP -n sim/tb_box.vvp
# Elaborate core_top + bridge handler + video + M3 SoC with stub IP. The template's own
# files use short positional port lists for synch_3 (core_top.v "synch_3 s01",
# core_bridge_cmd.v line 107) which Quartus accepts but Icarus reports as
# "Wrong number of ports"; those two errors are expected, anything else is not.
$IVERILOG -g2012 -o /dev/null -s core_top src/fpga/apf/common.v src/fpga/core/core_top.v \
    src/fpga/core/core_bridge_cmd.v src/fpga/core/ufo50_video.v src/fpga/core/soc/*.v \
    src/fpga/core/cpu/VexRiscv.v sim/stubs_altera.v 2>&1 \
    | grep -i "error" | grep -v "Wrong number of ports\|error(s) during elaboration" && exit 1 || true
echo "core_top elaboration: only the expected template synch_3 port-count messages"
