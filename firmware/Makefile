# UFO50 Pocket SoC firmware (M3 "hello").
#
#   make            -> build/hello.elf, and src/fpga/core/fw/boot_b{0..3}.hex (bitstream boot RAM)
#   make sim        -> build/hello_sim.elf and sim/fw/boot_b{0..3}.hex (simulation variant, -DSIM)
#
# Toolchain: xPack riscv-none-elf-gcc 14.2.0-3 (tools/fetch_rv32_toolchain.sh in ufo50-ap
# installs it to ~/.cache/ufo50-rv32/). Override CROSS=... if it lives elsewhere.
XPACK  ?= $(HOME)/.cache/ufo50-rv32/xpack-riscv-none-elf-gcc-14.2.0-3/bin
CROSS  ?= $(XPACK)/riscv-none-elf-
CC      = $(CROSS)gcc
OBJCOPY = $(CROSS)objcopy
SIZE    = $(CROSS)size
PYTHON ?= python3

ARCH    = -march=rv32imfd_zicsr_zifencei -mabi=ilp32d
CFLAGS  = $(ARCH) -O2 -g -ffreestanding -fno-builtin -fno-math-errno -Wall -Wextra -Wno-unused-parameter \
          -ffunction-sections -fdata-sections -Icommon
LDFLAGS = $(ARCH) -nostdlib -nostartfiles -Wl,--gc-sections -Wl,-Map,$@.map -T common/link.ld
SRCS    = common/crt0.S common/console.c common/dataslot.c common/libc_min.c hello/main.c

all: ../src/fpga/core/fw/boot_b0.hex
sim: ../sim/fw/boot_b0.hex

build/hello.elf: $(SRCS) common/*.h common/link.ld
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SRCS) -lgcc
	$(SIZE) $@

build/hello_sim.elf: $(SRCS) common/*.h common/link.ld
	@mkdir -p build
	$(CC) $(CFLAGS) -DSIM $(LDFLAGS) -o $@ $(SRCS) -lgcc
	$(SIZE) $@

../src/fpga/core/fw/boot_b0.hex: build/hello.elf
	$(OBJCOPY) -O binary $< build/hello.bin
	$(PYTHON) ../tools/bin2hex.py build/hello.bin ../src/fpga/core/fw/boot 32768

../sim/fw/boot_b0.hex: build/hello_sim.elf
	$(OBJCOPY) -O binary $< build/hello_sim.bin
	$(PYTHON) ../tools/bin2hex.py build/hello_sim.bin ../sim/fw/boot 32768

clean:
	rm -rf build

.PHONY: all sim clean
