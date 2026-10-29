# CPU: VexRiscv RV32IMFD for the UFO50 Pocket SoC

`VexRiscv.v` is generated Verilog, **do not edit it by hand**. It comes from
[SpinalHDL/VexRiscv](https://github.com/SpinalHDL/VexRiscv) (MIT licence, Copyright (c) 2016 Spinal HDL
contributors) and [SpinalHDL](https://github.com/SpinalHDL/SpinalHDL) v1.13.0 (core: LGPL-3.0 for the
compiler itself; the generated Verilog carries no licence restriction; lib: MIT), using the generator in
`gen/GenUfo50Cpu.scala`.

The configuration follows agg23's [openfpga-litex](https://github.com/agg23/openfpga-litex) (MIT), which
runs VexRiscv with a double-precision FPU at 57.12 MHz on the same Cyclone V. The differences are bigger caches,
a single core without the SMP/MMU logic, and native cache buses instead of LiteX's interconnect.

## Configuration (as generated)

| | |
|---|---|
| ISA | RV32IMFD + Zicsr + Zifencei, machine mode only, `misa` = IMFD. ABI `ilp32d` |
| Pipeline | 5 stages, full bypass, dynamic branch prediction with target cache (1024-entry history) |
| Multiply / divide | `MulPlugin` (DSP blocks), `MulDivIterativePlugin` divide (34 cycles) |
| FPU | `FpuPlugin` + internal `FpuCore`, single and double precision (`withDouble = true`); fdiv/fsqrt iterative |
| I$ | **64 KB, 2-way** (branch `ufo50-cache`; 16 KB before), 32-byte lines, 32-bit refill bus (`iBus_*`) |
| D$ | **32 KB, 2-way** (16 KB before), 32-byte lines, write-through, 64-bit CPU and memory width (`dBus_*`, needed for `fld`/`fsd`) |
| Replacement | I$: the way a free-running counter points at; D$: one round-robin pointer for all sets (VexRiscv's own policies, no LRU) |
| I/O (uncached) regions | `0x5xxxxxxx` (SDRAM alias) and `0x8xxxxxxx`-`0xFxxxxxxx` |
| Reset vector | `0x00000000` (boot RAM); `mtvec` reset value `0x20` (firmware sets it) |
| CSRs | `mcycle`/`minstret` (+ user `cycle`/`instret` read-only), `mtvec`, `mepc`, `mcause`, `mtval`, `mscratch`, `mie`/`mip`, `misa` |
| Interrupts | `timerInterrupt`, `externalInterrupt`, `softwareInterrupt` pins |
| D$ invalidate | custom instruction `0x0000500F` (`dcache_invalidate()` in `firmware/common/soc.h`); one cycle per set (512). Put a `nop` in front of it: the flusher starts from the execute stage, also on the wrong path of a mispredicted branch |

Bus protocols (native VexRiscv cache buses, adapted in `soc/ufo50_soc.v`):
- `iBus_cmd` (valid/ready, address, size = log2 bytes; 5 = one 32-byte line) -> `iBus_rsp` beats of 32 bits.
- `dBus_cmd` (valid/ready, wr, uncached, address, data[63:0], mask[7:0], size, last). Reads: one command, then
  4 x 64-bit `dBus_rsp` beats for a line (size 5) or 1 beat for an uncached access. Writes: one 64-bit beat per
  command, no response.

## Regenerating

Change the parameters with environment variables (defaults in brackets): `ICACHE_KB` [64], `DCACHE_KB` [32],
`CACHE_WAYS` [2], `FPU` [2 = F+D, 1 = F only, 0 = none], `DBUS_WIDTH` [64 with D, else 32].
If you change cache sizes, also change the `ICACHE_KB` / `DCACHE_KB` / `*_WAYS` localparams in `soc/ufo50_soc.v`
(reported in `SYS_CONFIG`, register `0x00C`). No size limit applies here: the 4 KB-per-way rule in
`IBusCachedPlugin`/`DBusCachedPlugin` is only for configurations with an MMU (`memoryTranslatorPortConfig`),
and this CPU has `StaticMemoryTranslatorPlugin` only. Keep each way's data RAM at most 8192 words deep
(I$ 2-way: up to 64 KB, D$ 2-way with 64-bit words: up to 128 KB), the deepest an M10K goes without an
output mux.

The committed `VexRiscv.v` is the default build (`ICACHE_KB=64 DCACHE_KB=32 CACHE_WAYS=2`, VexRiscv
baf7dc8, SpinalHDL v1.13.0). With `ICACHE_KB=16 DCACHE_KB=16` the same script reproduces the 16 KB file of
`ufo50-blit2` byte for byte; the diff between the two is only address/tag widths and RAM depths.

**With sbt (normal PC with internet access):**
```
git clone https://github.com/SpinalHDL/VexRiscv
cd VexRiscv
git checkout baf7dc82f855eddaf5b0a20a6802c526f127e38a      # the revision used for M3
copy <core-template>\src\fpga\core\cpu\gen\GenUfo50Cpu.scala src\main\scala\vexriscv\demo\
sbt "runMain vexriscv.demo.GenUfo50Cpu"
copy VexRiscv.v <core-template>\src\fpga\core\cpu\VexRiscv.v
```
(sbt needs a JDK 17/21. On Windows, set variables with `set DCACHE_KB=32` before `sbt`.)

**Without sbt/Maven (how this file was made, Linux):** `sh gen/build_offline.sh /tmp/vexgen` downloads Scala
2.12.18 from GitHub, clones SpinalHDL v1.13.0, VexRiscv and scopt, and compiles them with plain `scalac`.
`gen/FileUtils.java` and `gen/Affinity.java` are minimal stand-ins for commons-io and OpenHFT affinity,
which are only needed for simulation features. Takes about 5 minutes on 2 cores.

## Resource and timing notes

- Expected size: CPU core ~1.5-2k ALM, FPU (F+D) ~3-4k ALM and ~10-20 DSP, branch history 1024 x 54 bits
  = ~6 M10K. Caches (M10K = 1 KB of data each, tags extra): 16 KB + 16 KB = 32 data + 4 tag blocks;
  **64 KB + 32 KB = 96 data + 6 tag blocks** (I$ data 2 x 8192 x 32, tags 2 x 1024 x 19; D$ data 16 x
  2048 x 8, tags 2 x 512 x 20), i.e. about +66 M10K over the 16 KB build.
- The FPU and the 2-way cache hit logic are the likely critical paths at 57.75 MHz on the C8 device. If timing
  fails, first try `clk_sys` 51.975 MHz (`core_top.v`: `SYS_FREQ_STR`/`SYS_FREQ_HZ`), then
  `CACHE_WAYS=1` with 16 KB direct-mapped caches.
