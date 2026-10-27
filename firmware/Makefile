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
SRCS    = common/crt0.S common/console.c common/dataslot.c common/libc_min.c hello/main.c hello/m4.c \
          ../sim/periph/model/blit_model.c ../sim/periph/model/adpcm.c

all: ../src/fpga/core/fw/boot_b0.hex

# SoC blitter benchmark (simulation only): make bench -> build/bench/boot_b{0..3}.hex,
# run with: cd <dir containing sim/fw/boot_b*.hex> && Vvl_top $(cat preload.txt)  (tools/blitbench.py)
benchmix: build/benchmix/boot_b0.hex
build/benchmix/boot_b0.hex: common/crt0.S common/libc_min.c bench/main.c common/*.h common/link.ld
	@mkdir -p build/benchmix
	$(CC) $(CFLAGS) -DSIM -DMIXSTRESS $(LDFLAGS) -o build/benchmix/bench.elf common/crt0.S common/libc_min.c bench/main.c -lgcc
	$(OBJCOPY) -O binary build/benchmix/bench.elf build/benchmix/bench.bin
	$(PYTHON) ../tools/bin2hex.py build/benchmix/bench.bin build/benchmix/boot 32768
# make benchns: the same with the framebuffer scanout off (blitter cycles without video contention)
benchns: build/benchns/boot_b0.hex
build/benchns/boot_b0.hex: common/crt0.S common/libc_min.c bench/main.c common/*.h common/link.ld
	@mkdir -p build/benchns
	$(CC) $(CFLAGS) -DSIM -DNOSCAN $(LDFLAGS) -o build/benchns/bench.elf common/crt0.S common/libc_min.c bench/main.c -lgcc
	$(OBJCOPY) -O binary build/benchns/bench.elf build/benchns/bench.bin
	$(PYTHON) ../tools/bin2hex.py build/benchns/bench.bin build/benchns/boot 32768
bench: build/bench/boot_b0.hex
build/bench/boot_b0.hex: common/crt0.S common/libc_min.c bench/main.c common/*.h common/link.ld
	@mkdir -p build/bench
	$(CC) $(CFLAGS) -DSIM $(LDFLAGS) -Wl,-Map,build/bench/bench.map -o build/bench/bench.elf common/crt0.S common/libc_min.c bench/main.c -lgcc
	$(OBJCOPY) -O binary build/bench/bench.elf build/bench/bench.bin
	$(PYTHON) ../tools/bin2hex.py build/bench/bench.bin build/bench/boot 32768
sim: ../sim/fw/boot_b0.hex

build/hello.elf: $(SRCS) common/*.h hello/*.h common/link.ld
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SRCS) -lgcc
	$(SIZE) $@

build/hello_sim.elf: $(SRCS) common/*.h hello/*.h common/link.ld
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
