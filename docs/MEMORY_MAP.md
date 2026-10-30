# UFO50 Pocket SoC: memory map and peripheral contract (M3)

Status: **v0.2** (2026-10-25, implemented and simulated), branch `ufo50-m3`. This file is the contract between the SoC
(CPU, SDRAM, video, data slots: branch `ufo50-m3`), the blitter and audio mixer (branch `ufo50-periph`)
and the runtime port (`platform_pocket.c`). Changes to the port definitions in sections 4 and 5 are
listed in the changelog at the end.

## 1. Clocks and resets

| Clock | Frequency | Used by |
|---|---|---|
| `clk_sys` | **57.75 MHz** (74.25 MHz x 14 / 18, integer-mode PLL) | CPU, Wishbone bus, SDRAM controller, all MMIO slaves, blitter, mixer |
| `clk_sdram` | 57.75 MHz, phase shifted | `dram_clk` pin only |
| `clk_vid` | 12.288 MHz (template PLL) | video timing (`ufo50_video`), scanout line buffer read side |
| `clk_74a` | 74.25 MHz | APF bridge, data-slot command FSM |

Everything a peripheral sees (Wishbone slave port, SDRAM master port, IRQ line, audio strobe) is
**synchronous to `clk_sys`**. Reset for peripherals: `rst_sys` (active high, synchronous to `clk_sys`),
asserted while the PLL is unlocked or the APF holds the core in reset (`reset_n` low).
The SDRAM controller and the bridge-to-SDRAM path are **not** held in reset by `reset_n`: the APF writes
data slots into SDRAM before it releases reset.

## 2. CPU-visible address map

| Range | Size | Region | Cached | Notes |
|---|---|---|---|---|
| `0x0000_0000 - 0x0000_7FFF` | 32 KB | Boot RAM (M10K) | yes (I$, D$) | Firmware image, preloaded from the bitstream (`.hex`/`.mif`). Writable. Reset vector `0x0000_0000`. |
| `0x1000_0000 - 0x13FF_FFFF` | 64 MB | SDRAM | yes | Main memory. Code, data, heap, framebuffers, data slots. |
| `0x5000_0000 - 0x53FF_FFFF` | 64 MB | SDRAM, uncached alias | no | Same memory as `0x1000_0000`. Use for buffers written by DMA/blitter, or invalidate the D$ first. |
| `0x8000_0000 - 0x8000_FFFF` | 64 KB | System registers | no | Section 3.1 |
| `0x8001_0000 - 0x8001_FFFF` | 64 KB | Data-slot controller | no | Section 3.2 |
| `0x8002_0000 - 0x8002_FFFF` | 64 KB | **Blitter** (Wishbone slave) | no | Section 4. Real peripheral from M4 (`docs/BLITTER.md`, `docs/AUDIO_MIXER.md`); stub with test registers in M3 |
| `0x8003_0000 - 0x8003_FFFF` | 64 KB | **Audio mixer** (Wishbone slave) | no | Section 4. Real peripheral from M4 (`docs/BLITTER.md`, `docs/AUDIO_MIXER.md`); stub with test registers in M3 |
| `0x8004_0000 - 0x8FFF_FFFF` | | reserved (reads 0, writes ignored, acked) | no | |
| everything else | | unmapped (reads `0xDEAD_BEEF`, acked) | | |

The CPU treats `0x5xxx_xxxx` and `0x8xxx_xxxx` as I/O (uncached, no speculation). The D$ is
**write-through**: CPU stores reach SDRAM immediately, so hardware readers (video scanout, blitter)
see them without a flush. When hardware writes SDRAM that the CPU will read through the cached window
(data-slot DMA, blitter readback), the CPU must invalidate the D$ (`dcache_invalidate()` in
`firmware/common/soc.h`) or read through the uncached alias.

### Bridge (APF) address map

Bridge writes in `0x1000_0000 - 0x13FF_FFFF` go to SDRAM (same addresses as the CPU's cached window).
That is what the `address` fields of `data.json` and the `bridge address` parameter of target commands
`0x0180`/`0x0184` refer to. `0xF8xx_xxxx` is the APF command space. **Bridge reads** of the same range
return the SDRAM contents (v0.6, `soc/bridge_sdram.v`): the APF reads them for data-slot writes (target
command 0x0184) and when it writes the nonvolatile slots back to the card on quit/sleep/power-off. The
read side keeps two 32-byte blocks and prefetches the next block, so a sequential read sequence is served
without SDRAM latency after its first word; the blocks are invalidated by bridge writes and by any SDRAM
write to the same 2 KB row (the CPU rewriting a save region is always seen). Savestates are not supported.

### Default SDRAM layout (firmware/runtime convention, not hardware)

| CPU address | Size | Use |
|---|---|---|
| `0x1000_0000` | 40 MB | Slot 0 `ufo50.gmp` (loaded by APF at boot) |
| `0x1280_0000` | 8 MB | Slot 1 `ufo50.gma` (loaded by APF at boot) |
| `0x1300_0000` | 1 MB | Slot 4 `english.txt` (loaded by APF at boot) |
| `0x1310_0000` | ~14.4 MB | Heap / runtime `.bss` / deferload staging (runtime's choice) |
| `0x13F0_0000` | 512 KB | Reserved (blitter display lists, audio ring) |
| `0x13F8_0000` | 256 KB | Framebuffer 0 |
| `0x13FC_0000` | 256 KB | Framebuffer 1 |

The game runtime (ufo50-ap `docs/POCKET_RUNTIME.md`) uses its own layout; the parts fixed by `data.json`
(v0.6) are the **nonvolatile save slots**, loaded by the APF at boot and read back by it over the bridge:

| CPU / bridge address | Size max | Slot | File (`/Saves/ufo50/common/`) |
|---|---|---|---|
| `0x13E4_0000` | 128 KB | 10 | `save1.ufo` |
| `0x13E6_0000` | 128 KB | 11 | `save2.ufo` |
| `0x13E8_0000` | 128 KB | 12 | `save3.ufo` |
| `0x13EA_0000` | 64 KB | 13 | `account.ufo` |
| `0x13EB_0000` | 64 KB | 14 | `config.json` |

Note for the runtime team: 64 MB cannot hold the measured 70 MB resident heap; the `.gmp` has to be used
in place (no copy) and/or per game overlays. The 2 x 16 MB PSRAM is not mapped in M3 (planned for 8 bpp
texture pages, M4).

### IRQs

VexRiscv machine-mode interrupts:
- **Timer** (`mip.MTIP`): `MTIME >= MTIMECMP` (system registers).
- **External** (`mip.MEIP`): `|(IRQ_PENDING & IRQ_ENABLE)`. Sources:

| Bit | Source | Pending set by | Cleared by |
|---|---|---|---|
| 0 | VBLANK | start of vertical blank (after the last active line) | write 1 to `IRQ_PENDING` bit 0 |
| 1 | SLOT | data-slot command finished | write 1 to bit 1 |
| 2 | BLIT | blitter `irq` output (level) | the blitter (level-sensitive, mirrored) |
| 3 | AUDIO | mixer `irq` output (level) | the mixer (level-sensitive, mirrored) |
| 4 | BUTTON | any change of `cont1_key[15:0]` | write 1 to bit 4 |

The firmware in M3 polls; IRQs are wired and testable but not required.

## 3. MMIO registers

All registers are 32-bit, word aligned. Byte/half writes to registers are treated as full writes of the
selected lanes (sel). Undefined offsets read 0.

### 3.1 System registers, base `0x8000_0000`

| Offset | Name | R/W | Description |
|---|---|---|---|
| `0x000` | `SYS_ID` | R | `0x5546_3530` ("UF50") |
| `0x004` | `SYS_VERSION` | R | `0x0003_0000` (M3, major.minor) |
| `0x008` | `SYS_CLK_HZ` | R | `clk_sys` frequency in Hz (57,750,000) |
| `0x00C` | `SYS_CONFIG` | R | `[7:0]` I$ KB, `[15:8]` D$ KB, `[19:16]` I$ ways, `[23:20]` D$ ways, `[24]` FPU-D present, `[25]` blitter present (0 = stub), `[26]` mixer present (0 = stub) |
| `0x010` | `MTIME_LO` | R | 64-bit free-running `clk_sys` counter, low word (read LO first; HI is latched on LO read) |
| `0x014` | `MTIME_HI` | R | high word |
| `0x018` | `MTIMECMP_LO` | RW | timer compare, low (reset all ones) |
| `0x01C` | `MTIMECMP_HI` | RW | timer compare, high |
| `0x020` | `IRQ_PENDING` | R/W1C | Section 2, IRQs |
| `0x024` | `IRQ_ENABLE` | RW | same bit layout |
| `0x030` | `CONT1_KEY` | R | `cont1_key` (bit map in `core_top.v`: 0 up, 1 down, 2 left, 3 right, 4 A, 5 B, 6 X, 7 Y, 8 L1, 9 R1, 10 L2, 11 R2, 12 L3, 13 R3, 14 select, 15 start, 31:28 type) |
| `0x034` | `CONT1_JOY` | R | `cont1_joy` |
| `0x038` | `CONT1_TRIG` | R | `cont1_trig` |
| `0x03C` | `CONT2_KEY` | R | `cont2_key` (and `0x040`..`0x05C`: CONT2_JOY, CONT2_TRIG, CONT3_KEY, ... same stride pattern: KEY, JOY, TRIG per controller) |
| `0x060` | `RTC_EPOCH` | R | `rtc_epoch_seconds` from the APF (valid when `RTC_VALID`=1) |
| `0x064` | `RTC_VALID` | R | bit 0 |
| `0x070` | `OS_STATUS` | R | bit 0 `osnotify_inmenu` (Pocket menu open), bit 1 `dataslot_allcomplete` |
| `0x100` | `VID_STATUS` | R | bit 0 in vblank, bit 1 = buffer swap pending, `[23:16]` last framebuffer line fetched by the scanout (0..215) |
| `0x104` | `VID_FRAME` | R | frame counter, +1 at each vblank start |
| `0x108` | `FB_ADDR` | RW | Address of the **front buffer** (CPU byte address in `0x1000_0000`+, 256-byte aligned). The written value takes effect at the next vblank start (`VID_STATUS` bit 1 is set until then). Reset `0x13F8_0000`. |
| `0x10C` | `FB_ACTIVE` | R | address currently scanned out |
| `0x110` | `VID_CTRL` | RW | bit 1 = M1 test pattern (wins over bit 0), bit 0 = framebuffer scanout; both 0 = solid `VID_BORDER` colour. bit 2 = framebuffer format: 0 RGB565, 1 ABGR8888 (section 6); like `FB_ADDR` it takes effect at the next vblank start, so write both before waiting for the swap. **Reset value 2 (test pattern, RGB565)**: if the Pocket shows the M1 pattern, the firmware never started |
| `0x114` | `VID_BORDER` | RW | RGB888 colour shown when `VID_CTRL` = 0 |
| `0x120` | `SDRAM_STATUS` | R | bit 0 = SDRAM controller initialised |
| `0xFFC` | `DEBUG_OUT` | W | ignored by the hardware; the firmware writes progress markers here, which the simulation testbenches (and SignalTap) watch |

### 3.1a Memory performance counters (v0.9, branch `ufo50-perfctr`)

Read-only, in the system register window, free-running 32-bit `clk_sys` counts from reset (they wrap after
~74 s at 57.75 MHz: take differences over short windows). A core without them reads 0 there. They only
observe the CPU's buses and the SDRAM arbiter (nothing feeds back into the datapath).

| Offset | Name | Counts |
|---|---|---|
| `0x200` | `PC_IREFILL_N` | I$ line refills from SDRAM (iBus commands accepted with an SDRAM address) |
| `0x204` | `PC_IREFILL_CYC` | cycles of those refills, from the accept cycle to the 8th beat (the CPU's fetch stall) |
| `0x208` | `PC_DREFILL_N` | D$ line refills from SDRAM (line reads accepted) |
| `0x20C` | `PC_DREFILL_CYC` | cycles from the line read being presented (`dBus_cmd_valid`, including waiting for an earlier store to finish) to its last beat |
| `0x210` | `PC_DWRITE_N` | CPU stores to SDRAM accepted (the D$ is write-through: each store is one SDRAM write of 1-2 beats) |
| `0x214` | `PC_DWRITE_STALL` | cycles a store waited to be accepted (`valid & !ready`: the CPU is stalled; the fabric takes the next dBus command only after the previous store's write beat) |
| `0x218` | `PC_IO_N` | uncached reads (`0x5xxx_xxxx`) and MMIO accesses (reads and writes) |
| `0x21C` | `PC_IO_CYC` | their cycles, presented -> response / done |
| `0x220` | `PC_ARB_WAIT` | cycles in which a CPU SDRAM port (dBus 3 or iBus 4) has a request the arbiter has not granted (another master's access, or the controller busy/refreshing) |
| `0x224` | `PC_DBUS_WAIT` | cycles any dBus command waited to be accepted |
| `0x240`-`0x254` | `PC_OWNER[0..5]` | SDRAM busy cycles (arbiter access in progress) by port: 0 video, 1 bridge, 2 mixer, 3 dBus, 4 iBus, 5 blitter |

CPU cycles stalled on memory over a window = `IREFILL_CYC + DREFILL_CYC + DWRITE_STALL + IO_CYC` (an upper
bound: the I$ and D$ can overlap by a few cycles). The game runtime shows them on the perf overlay's second page
(ufo50-ap `runtime/pocket/perf.c`); `tools/rv32sim --soc --bus 1` models the same registers.

### 3.2 Data-slot controller, base `0x8001_0000`

Wraps APF target commands `0x0180` (data slot read), `0x0184` (data slot write) and `0x0188` (data slot
flush) and the data-slot size table. C driver: `firmware/common/dataslot.c`.

| Offset | Name | R/W | Description |
|---|---|---|---|
| `0x00` | `DS_SLOT_ID` | RW | slot id (16 bits) |
| `0x04` | `DS_OFFSET` | RW | byte offset inside the slot file |
| `0x08` | `DS_ADDR` | RW | SDRAM side of the transfer: CPU address in `0x1000_0000 - 0x13FF_FFFF` (bridge address) |
| `0x0C` | `DS_LENGTH` | RW | bytes |
| `0x10` | `DS_CMD` | RW | write **1** = start read (0x0180: slot file -> SDRAM), **2** = start write (0x0184: SDRAM -> slot file, the APF reads `DS_ADDR` over the bridge), **3** = flush (0x0188: write the slot back to the card; only `DS_SLOT_ID` is used). Ignored while busy; reads back the last command |
| `0x14` | `DS_STATUS` | R | bit 0 busy, bit 1 done (sticky until next start), bit 2 error, `[10:8]` APF error code (`target_dataslot_err`: 0x0180/0x0184: 1 slot not defined, 2 error / out of range), bit 16 `dataslot_allcomplete` |
| `0x100 - 0x1FC` | `DS_TABLE[64]` | **RW** | the APF data-slot size table (bridge `0xF800_2000`): word `2n` = slot id of entry n, word `2n+1` = size in bytes; the entries are in `data.json` order. Accesses stall ~10 bus cycles (clock crossing). Writable since v0.6: a nonvolatile slot's entry is what the APF writes back on quit/sleep/power-off |

Read: the APF writes the data through the bridge into SDRAM; the driver waits for `done`, then the CPU must
**invalidate the D$** (or read through `0x5xxx_xxxx`) before reading the destination.
Lengths and offsets: any multiple of 4 is safe; the APF handles the rest.

Write (saves): the CPU puts the file in the slot's SDRAM region (write-through D$, so plain stores are fine),
sets `DS_TABLE` size of the slot, then `DS_CMD = 2` with address/length (the APF reads the region through
`bridge_rd`), optionally `DS_CMD = 3`. The table entry alone is enough for the APF's own write-back when the
user quits the core, sleeps or powers off (the file is created if it did not exist). The runtime's
`saves.c` in ufo50-ap documents the full protocol; `firmware/hello/main.c` tests it in `-DSIM` builds
(`sim/verilator/tb_soc.cpp` models 0x0184/0x0188 and checks every word the APF read against its SDRAM model).

## 4. Peripheral slave windows (blitter, mixer): Wishbone B4 classic, 32-bit

One port per peripheral, in `clk_sys`. The peripherals are the modules **`ufo50_blitter`**
(`src/fpga/core/soc/ufo50_blitter.v`) and **`ufo50_mixer`** (`src/fpga/core/soc/ufo50_mixer.v`). In M3 both files
are stubs; branch `ufo50-periph` replaces the two files and keeps the module names and port lists below
(instantiated in `soc/ufo50_soc.v`). The SoC decodes the 64 KB window and drives:

```verilog
// SoC -> peripheral
input  wire        clk,          // clk_sys
input  wire        rst,          // rst_sys, active high, synchronous
input  wire [15:2] wb_adr,       // word address inside the 64 KB window
input  wire [31:0] wb_dat_w,
input  wire [3:0]  wb_sel,       // byte lanes, little endian (sel[0] = bits 7:0)
input  wire        wb_we,
input  wire        wb_cyc,
input  wire        wb_stb,       // cyc & stb = request; held until ack
// peripheral -> SoC
output wire [31:0] wb_dat_r,     // valid in the ack cycle
output wire        wb_ack,       // one cycle per transfer; may be delayed (wait states allowed)
output wire        irq,          // level, high = interrupt pending (IRQ bits 2 / 3)
// SDRAM master port: section 5 (mem_cmd_valid ... mem_rvalid)
output wire        present       // tie to 1 in the real peripheral (SYS_CONFIG bits 25 / 26)
```

`wb_cyc` and `wb_stb` are the same signal (window selected). Full port order of both modules: `clk, rst,
wb_adr, wb_dat_w, wb_sel, wb_we, wb_cyc, wb_stb, wb_dat_r, wb_ack, irq, mem_cmd_valid, mem_cmd_we,
mem_cmd_addr, mem_cmd_len, mem_wdata, mem_wstrb, mem_cmd_ready, mem_wready, mem_rdata, mem_rvalid,
[mixer only: audio_tick, audio_l, audio_r,] present`. Connect by name.

Rules: classic single transfers only (no `cti`/`bte`, no `err`/`rty`). The SoC keeps `cyc`/`stb` and all
inputs stable until `ack`, then drops `stb` for at least one cycle. `ack` must be asserted only while
`cyc & stb`. Latency should stay below 256 cycles; the CPU stalls meanwhile.

The audio mixer additionally gets:

```verilog
input  wire        audio_tick,   // one-cycle pulse in clk_sys at 48,000 Hz (sample request)
output wire [15:0] audio_l,      // signed PCM, sampled by the SoC on audio_tick
output wire [15:0] audio_r
```

The SoC serialises `audio_l/r` to I2S (48 kHz, 16-bit, the APF's audio format).

M3 stubs (`rtl/periph_stub.v`): offset `0x0` reads an ID (`0x424C_4954` "BLIT" / `0x4D49_5852` "MIXR"),
offsets `0x4..0x1C` are 7 scratch registers (RW), `0x20` write = start a 32-byte SDRAM copy test through
the master port (src at `0x24`, dst at `0x28`; `0x20` reads 1 while busy), irq = 0, audio = 0.

## 5. SDRAM master ports (blitter `X0`, mixer `X1`)

Two identical extra masters on the SDRAM arbiter, in `clk_sys` (blitter = arbiter port 5 "X0",
mixer = port 2 "X1"). `periph_stub.v` is a small working example of both interfaces:

```verilog
// master -> arbiter
output wire        mem_cmd_valid,
output wire        mem_cmd_we,       // 1 = write
output wire [25:2] mem_cmd_addr,     // SDRAM word address: (CPU address - 0x1000_0000) >> 2
output wire [5:0]  mem_cmd_len,      // beats - 1 (1..64 beats of 32 bits; 3 bits / 1..8 beats before v0.4)
output wire [31:0] mem_wdata,        // current write beat
output wire [3:0]  mem_wstrb,        // byte enables of the current write beat
// arbiter -> master
input  wire        mem_cmd_ready,    // command accepted when valid & ready
input  wire        mem_wready,       // write beat consumed (one pulse per beat)
input  wire [31:0] mem_rdata,
input  wire        mem_rvalid        // read beat (one pulse per beat, in order)
```

Protocol:
- **Burst limits** (v0.4): 1..64 beats, and a burst must not cross a **2 KB SDRAM row** (`addr[10:2] + len <= 511`).
  Long bursts are much cheaper per byte (see the cost line below). The blitter (v0.7) uses up to 64 beats, cut
  only at 2 KB rows; `periph_mem_port` (mixer) up to 32 beats inside aligned 128-byte blocks; the scanout uses
  64-beat (256 B) bursts; the CPU ports and the APF bridge stay at 8.
- **Command**: the master holds `valid`, `we`, `addr`, `len` until `ready`. `ready` may come many cycles
  later (arbitration, refresh). The command is accepted in the cycle with `valid & ready`.
- **Write data** is pulled: beat 0 must be on `wdata/wstrb` when the command is presented. The arbiter
  pulses `wready` once per beat (beat 0 at the earliest in the acceptance cycle); after each `wready`, the
  master puts the next beat on `wdata/wstrb` in the **next** cycle. Beats can be consecutive-cycle pulls,
  so a master should keep the burst in a small FIFO/register file and index it with a beat counter.
  `wstrb = 0` is allowed (beat skipped in memory).
- **Read data**: `len+1` `rvalid` pulses in address order, no backpressure (the master must accept).
- **One outstanding command per port**: after acceptance, the next command is accepted only after the
  last `wready` (write) or the last `rvalid` (read). Holding `valid` early is fine.
- Cost: a closed-page access of n beats takes 2n + 7 `clk_sys` cycles in the controller (ACTIVE, tRCD, n READ/WRITE
  commands two clocks apart, auto-precharge and recovery), plus a few cycles of arbitration: 8 beats (32 B) ~23-26
  cycles (~70% of the bus rate), 32 beats ~71 (~90%), 64 beats ~135 (~95%).
- Worst-case wait for a high-priority port is one access in progress: up to ~140 cycles (a 64-beat scanout burst).
- Arbitration (fixed priority, may be tuned; not part of the contract): video scanout > bridge (APF) >
  `X1` mixer > CPU D-bus > CPU I-bus > `X0` blitter. `mem_rdata` is shared by all ports: it is only
  meaningful in a cycle where your own `mem_rvalid` is high.
- The CPU's D$ is not snooped. After the blitter writes memory the CPU will read (rare: the framebuffer is
  write-only for the CPU), the CPU invalidates its D$ or reads through `0x5xxx_xxxx`. A master must not assume a bound on `ready`
  latency, but video takes ~12% of SDRAM time in RGB565 and ~25% in ABGR8888 (frame average; up to ~50% during
  active lines), and a CPU burst is <= 32 B.
- Peak bandwidth: 16-bit SDR at 57.75 MHz = 115 MB/s raw; ~80 MB/s for 32-byte bursts, ~105-110 MB/s for
  64-beat bursts. Refresh every 300 cycles (5.2 us), so a refresh delayed by the longest access still meets tREFI.

## 6. Framebuffer format

Two formats, selected by `VID_CTRL` bit 2 (latched at vblank together with `FB_ADDR`):

**ABGR8888 (bit 2 = 1, M4+, what the game runtime uses)**: 384 x 216 x 32-bit `0xAABBGGRR` (R in bits 7:0,
alpha ignored by the scanout), exactly the pixel format the blitter writes (`docs/BLITTER.md`). Pixel (x, y) at
`FB_ADDR + y*1536 + x*4`, stride 1536 bytes, size 331,776 bytes, so it does **not** fit the 256 KB RGB565
slots below. The M4 firmware uses `0x13A0_0000` / `0x13A8_0000`; the runtime should move its two buffers to
512 KB-aligned slots of its choice. Full 8-bit RGB goes to the Pocket. Scanout cost: 48 x 32-byte bursts per
line (vs 24), about 50% of SDRAM time during active lines and ~25% averaged over the frame.

**RGB565 (bit 2 = 0, reset default, M3 text console)**:

- 384 x 216 pixels, **RGB565**, little-endian 16-bit (`pixel = r5<<11 | g6<<5 | b5`), pixel (x, y) at
  `FB_ADDR + y*768 + x*2`. Stride 768 bytes, size 165,888 bytes. Two pixels per 32-bit word: the
  left pixel in bits 15:0.
- Scanout expands to RGB888 by bit replication. It prefetches each line during the previous line
  (512-clock lines at 12.288 MHz), so frame timing is exactly the M1 timing (60.000 Hz).
- Double buffering: draw into the back buffer, write its address to `FB_ADDR`, then wait until
  `VID_STATUS` bit 1 clears (or the VBLANK IRQ) before drawing into the old front buffer.
- Vertical blank is 184 of 400 lines (46% of the frame, ~7.7 ms).

## 7. CPU configuration

VexRiscv (SpinalHDL, MIT), single core, RV32IMFD (+Zicsr, Zifencei), ilp32d, machine mode only, 64 KB 2-way
I$ and 32 KB 2-way D$ (branch `ufo50-cache`; 16 KB + 16 KB before; 32-byte lines, D$ write-through, 64-bit
data path), 57.75 MHz. Read the sizes from `SYS_CONFIG` rather than assuming them. `dcache_invalidate()`
stalls the CPU one cycle per D$ set (512 with 32 KB 2-way, was 256); `fence.i` one per I$ set (1024, was 256). See `src/fpga/core/cpu/README.md`
for the exact generator configuration and how to regenerate.
Toolchain flags: `-march=rv32imfd_zicsr_zifencei -mabi=ilp32d`.
`rdcycle`/`rdcycleh`, `rdinstret` work. D$ invalidate: `dcache_invalidate()` (instruction `0x0000500F`);
I$ invalidate: `fence.i`. The FPU must be enabled before use (`mstatus.FS`, done in `crt0.S`).

## 8. Notes for the runtime port (`platform_pocket.c`)

- **Toolchain**: xPack `riscv-none-elf-gcc` 14.2.0-3, `-march=rv32imfd_zicsr_zifencei -mabi=ilp32d`. The
  newlib multilib `rv32imfd_zicsr/ilp32d` matches. Starting point: `firmware/common/` (crt0, link script,
  `soc.h`, `dataslot.c`, text console).
- **Where code runs**: the boot RAM is only 32 KB. The runtime (~600 KB `.text`, ~5 MB `.bss`) must run from
  SDRAM. Plan: a small boot RAM loader reads the runtime ELF/binary from a data slot (or it is part of slot 0)
  into SDRAM, invalidates the I$ (`fence.i`) and jumps. Linker script: `.text/.data/.bss` in SDRAM above the
  slot data, e.g. from `0x1310_0000`; stack at the top of the heap region (below `0x13F0_0000`).
- **Heap**: whatever is left between the end of `.bss` and `0x13F0_0000` (~14 MB with the default slot layout).
  Slot 0 (`.gmp`, up to 40 MB) and slot 1 (`.gma`, 8 MB) are already in memory at boot: parse them in place,
  don't copy. 64 MB cannot hold the PC build's 70 MB resident heap; texture pages go to PSRAM in M4.
- **Files**: slots loaded at boot are plain memory (`0x1000_0000`, `0x1280_0000`, `0x1300_0000`; sizes from
  `ds_slot_size()`). Deferload slots (2 texture pack, 3 audio pack) are read with `ds_read(id, offset, dst, len)`;
  `ds_read_start()`/`ds_busy()` allow overlapping the transfer with other work. The bridge delivers a few MB/s.
  Saves (slots 10-14): nonvolatile, loaded by the APF at boot into the regions in section 2; the runtime
  writes them back with `DS_TABLE` + `DS_CMD` 2/3 (`ds_write()`, `ds_flush()`, `ds_table_set()` in
  `firmware/common/dataslot.c`), v0.6.
- **Time**: `rdcycle` (57.75 MHz) or `MTIME` (same clock, 64-bit). Frame pacing: `wait_vblank()` or the VBLANK
  IRQ; the video is exactly 60.000 Hz.
- **Video**: draw RGB565 into the back buffer, write `FB_ADDR`, wait for `VID_STATUS.SWAP_PEND` = 0.
  CPU stores to the framebuffer are slow (one SDRAM write each, ~10 cycles): M4's blitter does the drawing.
- **Input**: `CONT_KEY(0..3)` (bit map in section 3.1), `CONT_JOY`, `CONT_TRIG`.
- **Coherency**: after `ds_read()` the driver already invalidates the D$. Self-modifying code / loaded code
  needs `fence.i`.

## Changelog

- v0.9 (2026-10-30, branch `ufo50-perfctr`): memory performance counters (section 3.1a, sysregs `0x200`-`0x254`)
  only; no datapath change. Verilator: `sim/membench` (CPU latency under a real blitter frame + scanout) and
  per-access latency histograms in `tb_soc.cpp`.
- v0.1 (2026-10-25): first draft.
- v0.8 (2026-10-28, branch `ufo50-cache`): **bigger CPU caches**, I$ 16 -> 64 KB, D$ 16 -> 32 KB (both still
  2-way, 32-byte lines). `SYS_CONFIG` reports 64 / 32. No register, port or memory-map change.
- v0.7 (2026-10-27, branch `ufo50-blit2`): **blitter throughput**. No register, command or port change: the
  blitter drives its `X0` port directly with up to 64-beat accesses (cut at 2 KB rows), reads the destination
  only for rows with a translucent texel, splits writes at transparent gaps and drops a `CLEAR` that the next
  command (a `CLEAR` of the same rectangle) overwrites. Real Pocket game frames need 33-60% fewer blitter
  cycles (`docs/BLITTER.md`, Throughput). `PERF_PIXELS` does not count a dropped `CLEAR`'s pixels.
- v0.6 (2026-10-26, branch `ufo50-saves`): **saves**. Bridge reads of SDRAM (`bridge_sdram.v` read side with
  block prefetch and row-snoop invalidation; SDRAM port 1 now reads and writes), `DS_CMD` values 2 (0x0184)
  and 3 (0x0188, added to `core_bridge_cmd.v`), writable `DS_TABLE`, the save slot regions at `0x13E4_0000`
  (`data.json`). No change to the peripheral contract or to the SDRAM clocking (`SDRAM_2X = 0`).
  Verified in Verilator: hello (both SDRAM controllers), boot6, and the new 0x0184/0x0188 test.
- v0.2 (2026-10-25): matches the implementation. **No change to the peripheral ports of sections 4-5**, only
  additions: module/file names `ufo50_blitter`/`ufo50_mixer`, a `present` output, and the arbiter port numbers.
  Registers: `VID_STATUS[23:16]` is the last fetched line (was "current line"); `VID_CTRL` reset value is 2
  (test pattern); new `SDRAM_STATUS` (0x120) and `DEBUG_OUT` (0xFFC); section 8 (runtime notes) added.
- v0.5 (2026-10-25, branch `ufo50-m5`): **SDRAM on its own 115.5 MHz clock** (`soc/sdram_ctrl2x.v`, CL=3,
  2 x clk_sys from the same PLL, dual-clock FIFOs to the clk_sys arbiter; `SDRAM_2X` in core_top selects it,
  0 = the M4 controller). The port contract is unchanged; a beat now moves every clk_sys cycle, writes are
  posted (the arbiter is released once the beats are queued) and an access costs ~n + 4 clk_sys cycles plus
  ~4 cycles of FIFO latency. Benchmark: Barbuta 413k, library 438k blitter cycles per frame (from 946k /
  1,005k in M4), bit-exact; CPU D$ line refill 30 -> 24 cycles.
- v0.4 (2026-10-25, branch `ufo50-m5`): **SDRAM bursts up to 64 beats** within a 2 KB row (`mem_cmd_len` is
  6 bits), refresh every 300 cycles. Real Barbuta/library frames replayed on the SoC (`firmware/bench`,
  `tools/blitbench.py`): blitter time per frame 946k -> 710k / 1,005k -> 768k cycles, bit-exact.
- v0.3 (2026-10-25, branch `ufo50-m4`): the real blitter/mixer replace the stubs (`SYS_CONFIG` bits 25/26 read
  1). New `VID_CTRL` bit 2: ABGR8888 framebuffer format, needed because the blitter writes 32-bit pixels.
  RGB565 stays the reset default, so M3 firmware behaves exactly as before.
