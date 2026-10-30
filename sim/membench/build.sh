#!/bin/sh
# build.sh - build the memory-contention benchmark image (sim/out/membench.bin, .elf); slot-6 "U5RT" image
# like sim/cachebench (same start.S / link.ld). Toolchain as for firmware/.
set -e
cd "$(dirname "$0")"
X=${XPACK:-$HOME/.cache/ufo50-rv32/xpack-riscv-none-elf-gcc-14.2.0-3/bin}/riscv-none-elf-
mkdir -p ../out
python3 gen_funcs.py 640 ../out/membench_funcs.c
${X}gcc -march=rv32imfd_zicsr_zifencei -mabi=ilp32d -O2 -ffreestanding -fno-builtin -nostdlib -nostartfiles \
    -fno-reorder-functions -T ../cachebench/link.ld -o ../out/membench.elf ../cachebench/start.S membench.c ../out/membench_funcs.c -lgcc
${X}objcopy -O binary ../out/membench.elf ../out/membench.bin
${X}size ../out/membench.elf
