#!/bin/sh
# build.sh - build the cache benchmark image (sim/out/cachebench.bin, .elf). Toolchain as for firmware/.
set -e
cd "$(dirname "$0")"
X=${XPACK:-$HOME/.cache/ufo50-rv32/xpack-riscv-none-elf-gcc-14.2.0-3/bin}/riscv-none-elf-
mkdir -p ../out
python3 gen_funcs.py 640 ../out/cachebench_funcs.c
${X}gcc -march=rv32imfd_zicsr_zifencei -mabi=ilp32d -O2 -ffreestanding -fno-builtin -nostdlib -nostartfiles \
    -fno-reorder-functions -T link.ld -o ../out/cachebench.elf start.S align.S cachebench.c ../out/cachebench_funcs.c -lgcc
${X}objcopy -O binary ../out/cachebench.elf ../out/cachebench.bin
${X}size ../out/cachebench.elf
