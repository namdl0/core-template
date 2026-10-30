# Building the UFO 50 Pocket core (milestone M3)

This branch (`ufo50-m3`) turns the M1 test-pattern core into a small computer: a **VexRiscv RV32IMFD
soft CPU** (16 KB + 16 KB caches, double-precision FPU) at 57.75 MHz, 64 MB SDRAM, a double-buffered
384x216 RGB565 framebuffer, and data-slot loading. A C program ("hello") is built into the bitstream
and shows the M3 exit test on screen. The memory map and peripheral contract is
[`docs/MEMORY_MAP.md`](docs/MEMORY_MAP.md).

The steps below assume Windows. Linux works the same way. Use `python3` instead
of `py`, and `/media/...` instead of `E:\`.

## Blitter-burst preemption (branch `ufo50-preempt`)

`ufo50-preempt` = `ufo50-perfctr` plus one SDRAM arbiter change: the blitter's long bursts (up to 64 beats,
~135 cycles) **yield** when any other master (CPU, scanout, mixer, bridge) is waiting. The 1x controller ends the
burst after the current beat once it has moved 4 beats (auto-precharge, so the SDRAM timing is that of a normal
shorter access) and the arbiter issues the rest later; the blitter sees the same port protocol (one accept, all its
beats in order, with a gap). Why: the CPU's I$/D$ refills and stores could each wait a whole blitter burst. With the
counters (ufo50-perfctr) and Verilator (`sim/membench`, a real Vainger frame replayed by the blitter while the CPU
runs an interpreter-like mix with the scanout on):

| while the blitter runs | ufo50-perfctr | ufo50-preempt |
|---|---|---|
| D$ refill, avg cycles (miss loop) | 145 | 46 |
| I$ refill, avg cycles (code loop) | 124 | 38 |
| store stall per store (mix) | 31.7 | 13.6 |
| interpreter-like mix, total cycles | 1.70M | 1.17M (-31%) |
| real Vainger frame, blitter alone, cycles | 1,186,829 | 1,189,584 (+0.2%), bit-exact |

Nothing changes while the blitter is idle. When the CPU misses continuously the blitter gets less of the SDRAM
(55% -> 45% of the time in the mix above), so blitter-bound scenes can lose a little while the CPU is busy.

Build, package and copy exactly as for `ufo50-cache`. Expect a few dozen ALMs more than ufo50-perfctr. **Timing to
watch**: the new combinational path is arbiter `busy/owner` + the CPU ports' `p_valid` -> controller `stop` ->
`cut` -> the A10 bit of the SDRAM command (`sd_a`) and the arbiter's `left`/`pend_*` registers; if it shows up in the
worst paths of `clk_sys`, send them. The SDRAM pin timing is unchanged (same registered outputs). On the Pocket:
everything must look exactly as before (watch for wrong pixels in sprites/backgrounds: a broken continuation would
put blitter data at the wrong address), and the overlay's page 2 should show much lower `IC`/`DC` refill cycles in
scenes with a busy blitter. If anything looks wrong, flash ufo50-perfctr again.

## Memory performance counters (branch `ufo50-perfctr`)

`ufo50-perfctr` = `ufo50-cache` plus read-only **memory performance counters** in the system registers
(`0x200`-`0x254`, `docs/MEMORY_MAP.md` 3.1a): I$ and D$ SDRAM refills and their cycles, CPU stores to SDRAM and the
cycles they stalled the CPU, uncached/MMIO cycles, CPU arbiter wait, and SDRAM busy cycles per master. They only
observe; the CPU, caches, arbiter and controller are unchanged. Purpose: the Pocket's perf overlay showed the CPU
2-3x slower than the simulator predicted while the blitter matched; these counters show on the device where the
CPU's time goes (ufo50-ap branch `perf-counters`: overlay page 2).

Build, package and copy exactly as for `ufo50-cache`. Expect about +500-700 ALMs (16 x 32-bit counters and a read
mux), no M10K change; timing should stay close to `ufo50-cache`'s (+1.498 ns).

On the Pocket, with the `perf-counters` `ufo50rt.bin`: L+R shows the overlay, then **tap L alone** for page 2:
`IC <refills/frame> <avg cycles>C DC ...`, `ST <stores/frame> <stall per store>C IO ...`,
`MEM <stall cycles/frame> <% of time> BL<% SDRAM busy for the blitter> VI<% for the scanout>`, and
`I64K D32K 57.75MHZ` (from `SYS_CONFIG`: confirms which core is loaded). Photos of page 1 and page 2 on the same
screens as before (library, Barbuta, Golfaria/Grimstone text) are what is needed. With an older core, page 2 says
`NO MEM COUNTERS IN THIS CORE`.

Simulation: `sim/membench` (build with `sh sim/membench/build.sh`) runs from SDRAM like the game and measures the
CPU with only the scanout and then while the blitter replays a real captured frame (`+preload=` files of
`tools/blitbench.py`, as `firmware/bench`); `tb_soc.cpp` prints latency histograms per test (`MEMHIST`).

## Bigger CPU caches (branch `ufo50-cache`)

`ufo50-cache` = `ufo50-blit2` plus a CPU with **64 KB I$ and 32 KB D$** (both still 2-way, 32-byte lines;
was 16 KB + 16 KB) and one firmware fix, nothing else: same registers, data slots, clocks
(57.75 MHz, `SDRAM_2X = 0`) and file list (no `.qsf` change). In the simulator (ufo50-ap `rv32sim --soc`,
VexRiscv cache model) the game runtime needs 12-32% fewer CPU cycles per frame (Fist Hell -23%,
Grimstone -20%, Vainger -20%, Golfaria -19%, Onion Delivery -18%, Kick Club -15%, Barbuta -15%,
the library -32%). In Verilator the cache benchmark (`sim/cachebench`) runs its interpreter-like mix in
43% fewer cycles.

What changed:
- `src/fpga/core/cpu/VexRiscv.v`: regenerated (`cpu/README.md`); only RAM depths and tag/address widths
  differ from the 16 KB file. `soc/ufo50_soc.v`: `SYS_CONFIG` takes the sizes from four localparams.
- `firmware/common/soc.h`: `dcache_invalidate()` has a `nop` in front. VexRiscv starts its D$ flush when
  the instruction reaches the execute stage, before an older branch has resolved, so an invalidate right
  behind a mispredicted branch emptied the whole D$ for nothing (256 cycles, 512 with the new D$). The
  hello SDRAM march did that once per loop iteration (simulation: 0.1 s -> 0.2 s on the test screen with
  the bigger D$); with the nop it shows 0.0 s. On the Pocket the full 63.5 MB march gets much faster too. The boot firmware `.hex` files are rebuilt with it.

Build, package and copy exactly as for `ufo50-blit2` (`git checkout ufo50-cache`). Check in the compile report:
- **Resources**: **RAM blocks about 161 -> 227 of 308** (+66 M10K: I$ data 2 x 8192 x 32 = 64 blocks,
  was 16; I$ tags 2 x 1024 x 19 = 4, was 2; D$ data 16 x 2048 x 8 = 32, was 16; D$ tags 2 x 512 x 20 = 2);
  block memory bits +562 Kbit (1.12 M -> ~1.68 M of 3.15 M). ALMs about the same (+0-300). If Quartus reports
  noticeably more M10K than ~230, send the **RAM Summary** lines for `cpu|...|banks_*`, `ways_*_tags` and
  `ways_*_data_symbol*` (it may have picked a wider mode with an output mux).
- **Timing** (57.75 MHz clock `mp2|...|general[0]`, was +2.168 ns): two paths get a bigger fanout and
  should be watched in **Report Top Failing Paths** / the worst 10 paths of that clock:
  1. D$ address: the execute-stage adder `execute_SRC_ADD` -> the address registers of
     `dataCache_1|ways_*_data_symbol*` and `ways_*_tags` (now 34 M10K, was 18). This is the classic
     VexRiscv critical path; expect it to lose a few tenths of a ns.
  2. I$ address: `IBusCachedPlugin` prefetch PC (`io_cpu_prefetch_pc`) -> `banks_0/1` (now 64 M10K in
     8192 x 1 mode, was 16) and the tag RAMs.
  The way-select / hit logic is unchanged (still 2 ways, the tag compares are 1-2 bits narrower).
  Positive slack = fine. If it fails, send the first lines of the failing paths; the fallbacks are, in
  order, I$ 32 KB (`ICACHE_KB=32`, 32 data M10K, keeps about 3/4 of the gain) or D$ 16 KB
  (`DCACHE_KB=16`), regenerated as in `cpu/README.md` with the localparams in `ufo50_soc.v` changed to match.

On the Pocket:
- The M4 test screen (no `ufo50rt.bin` on the card) must say `I$ 64K 2-way  D$ 32K 2-way  FPU F+D` and
  PASS everywhere as before; the `SDRAM ... march PASS` time should be much shorter than with the old
  build (please note both numbers).
- Games: everything should look exactly the same and run faster wherever the CPU was the limit
  (Fist Hell, Golfaria, Vainger, Grimstone, Onion Delivery, Kick Club, the library). The blitter-bound
  games (Valbrace, Hyper Contender, Overbold, Avianos) do not change much.
- If anything is wrong, flash the `ufo50-blit2` bitstream again; nothing else on the SD card changes.

## Blitter throughput (branch `ufo50-blit2`)

`ufo50-blit2` = `ufo50-m5` (with saves) plus a faster blitter, nothing else: same registers, commands, data slots,
SDRAM clocking (`SDRAM_2X = 0`) and file list (no `.qsf` change). The blitter now writes straight to the SDRAM port
in long bursts, skips destination reads that cannot change the result, skips transparent gaps and drops a
full-screen `CLEAR` that the next `CLEAR` overwrites (`docs/BLITTER.md`, Pipeline). On real frames of the
blitter-bound games it needs 33-60% fewer cycles (Valbrace -60%, Hyper Contender -51%, Avianos -48%, Overbold
-42%, Quibble Race -38%, Vainger -33%; Barbuta and the library -15%), every frame bit-exact with the C model.

Build, package and copy exactly as for M5 (`git checkout ufo50-blit2`). Check in the compile report:
- **Timing**: the 57.75 MHz clock (`general[0]`) must still have positive setup slack (M4 had Fmax 65.5 MHz).
  If it fails, send the first lines of "Report Top Failing Paths".
- **Resources**: expect roughly +400-600 ALMs and +1-2 M10K blocks over the M5 build.

On the Pocket:
- **M4 test screen** (shown when there is no `ufo50rt.bin` on the card): the line `BLIT 11 cmds vs C model PASS` must still say
  PASS; its cycle count drops (simulation: 50,277 -> 43,849). In the blitter demo (SELECT) the `blit <N>k cyc`
  number should be lower than with the M5 build.
- **Games**: Valbrace, Hyper Contender, Overbold, Avianos, Quibble Race, Party House, Night Manor, Rakshasa,
  Star Waspir should run noticeably smoother; Vainger stays mostly CPU-bound. Look for any wrong pixels
  (missing or garbled sprites, translucent effects - shadows, glows, fades - drawn wrong, a frame that is not
  cleared): the hardware was checked bit-exact in simulation, so any difference is worth a photo.
- If anything is wrong, flash the M5/saves bitstream again; nothing else on the SD card changes.

## M5 (branch `ufo50-m5`): fast SDRAM and the game runtime

`ufo50-m5` = M4 plus:
- **SDRAM at 115.5 MHz** (`soc/sdram_ctrl2x.v`, CL=3; bursts up to 64 beats): memory bandwidth roughly
  doubles, the blitter's heavy frames drop from ~19 ms to ~7.4 ms in simulation. This is the part only real
  hardware can prove: if the Pocket shows a wrong picture, flicker, or `SDRAM ... FAIL`, set `SDRAM_2X = 0`
  in `src\fpga\core\core_top.v` (keeps the fast bursts on the old 57.75 MHz SDRAM clock) and recompile.
- **A bootloader for the game runtime** (docs/POCKET_RUNTIME.md in the `ufo50-ap` repo): new data slot 6
  loads `ufo50rt.bin` at `0x1288_0000`; the boot firmware checks its "U5RT" header and jumps to it. With no
  `ufo50rt.bin` on the card the Pocket boots into the M4 hello screen exactly as before. New deferload
  slots: 5 `ufo50_room.bin`, 7 `ufo50.masks`, 8 `ufo50.paths`; the asset index moved to `0x1240_0000` and
  `english.txt` to `0x1280_0000` (data.json).

Game files for the runtime go in `E:\Assets\ufo50\common\`: everything `tools/pocket_assets.py` writes to
`build/pocket/` in the `ufo50-ap` repo (ufo50.gmp, ufo50.gma, english.txt, ufo50_tex.bin, ufo50_snd.bin,
ufo50_room.bin, ufo50.masks, ufo50.paths) plus `ufo50rt.bin` from `make -C runtime pocket` there.

Build and package exactly as for M4/M3 below (`git checkout ufo50-m5`). In the timing check, **both** `mp2`
clocks (57.75 MHz `general[0]` and 115.5 MHz `general[1]`) must show positive setup slack.

## M4 (branch `ufo50-m4`): real blitter and audio mixer

`ufo50-m4` = M3 + the hardware blitter and 32-voice mixer from `ufo50-periph` (`src/fpga/core/periph/`,
`docs/BLITTER.md`, `docs/AUDIO_MIXER.md`) in place of the M3 stubs, plus:
- **ABGR8888 framebuffer mode** (`VID_CTRL` bit 2, `docs/MEMORY_MAP.md` §6): the blitter writes 32-bit pixels,
  so the scanout can now read them (full 24-bit colour to the Pocket). RGB565 stays the default, so the text
  screen is unchanged.
- The hello firmware (`firmware/hello/m4.c`) now tests the real peripherals.

Build and package exactly as for M3 (steps 2-6 below, `git checkout ufo50-m4`). On the Pocket the text screen
is the same as M3 except the last two test lines, which now read for example
```
BLIT 11 cmds vs C model PASS  1234 cyc
MIX  48000 Hz  adpcm blip 100 ms  und 0  PASS
```
- **BLIT**: the hardware ran a mix of fills, blits (flip, tint, 50% alpha, additive, subtract, fog), a scaled
  `BLIT_MAP` and a clear, and its output matched the bit-exact C model pixel for pixel. FAIL with `bad px N`
  = N pixels differ; FAIL with no count = the blitter never finished (timeout).
- **MIX**: the measured sample rate (should be 48000 +/- 1000), the ADPCM one-shot's play time (about 100 ms)
  and output underruns (should be 0).
- **Sound:** a ~0.3 s 441 Hz beep while the MIX line is being tested, fading out, then a short higher "blip".
- In the live area, **A** plays the blip again, and **SELECT** opens the **blitter demo**: scrolling brown
  tiles, six bouncing saucers (one see-through, one brighter/additive), a saucer that grows and shrinks in the
  bottom-right corner, and two lines of text at the top. The second line is a live measurement:
  `blit <N>k cyc  wait <W>k  mix <M>  und <U>` = blitter busy cycles per frame (thousands), of which cycles
  spent waiting for SDRAM, mixer cycles for the last sample, and audio underruns. B tints the saucers blue.
  SELECT goes back to the text screen. In simulation the demo frame needs ~1,100k blitter cycles (about 19 ms,
  so the demo runs at ~30 fps), ~84% of it waiting for SDRAM: please note the numbers your Pocket shows.

Please report: a photo of the text screen and of the demo, whether you heard the beep and the blip, and the
Quartus resource/timing numbers (the blitter + mixer add roughly 7,500 LUTs and ~30 M10K blocks by the
periph agent's estimate; the 57.75 MHz clock must still have positive slack, see step 3a otherwise).

## What's new in M3

| Path | What it is |
|---|---|
| `src/fpga/core/cpu/VexRiscv.v` | Generated CPU (RV32IMFD, 16 KB 2-way I$/D$; 64 KB / 32 KB since `ufo50-cache`). `cpu/README.md`: configuration, licence, how to regenerate |
| `src/fpga/core/soc/` | SoC: `ufo50_soc.v` (bus fabric, boot RAM, system registers), `sdram_ctrl.v` + `sdram_arb.v`, `vid_scanout.v`, `bridge_sdram.v` (APF -> SDRAM), `dataslot_ctrl.v` (target command 0x0180), `ufo50_blitter.v` / `ufo50_mixer.v` (M3 stubs, replaced in M4/M6) |
| `src/fpga/core/mf_pllsys.v` | System PLL, 74.25 -> 57.75 MHz |
| `src/fpga/core/fw/boot_b0..3.hex` | The hello firmware, preloaded into the 32 KB boot RAM by the bitstream |
| `src/fpga/core/core_top.v` | Instantiates the SoC, drives the SDRAM pins, I2S from the mixer port |
| `src/fpga/core/ufo50_video.v` | Same M1 timing; now also shows the framebuffer (or the M1 pattern, or a solid colour) |
| `firmware/` | Bare-metal C: `common/` (crt0, link script, `soc.h`, text console, data-slot driver), `hello/main.c`, `Makefile` |
| `sim/` | `sdram_model.v`, `tb_soc.v` (Icarus), `verilator/` (Verilator testbench, the one used for the full run) |
| `tools/pocket_pack.py` | New: `testfile` / `crc` commands for the slot-0 test; checks slot addresses against the SDRAM map |

Video timing is unchanged from M1: 12.288 MHz pixel clock, 512 x 400 total, exactly 60 Hz.

## Video timing

| | Value |
|---|---|
| Pixel clock | **12.288 MHz**, the template PLL's `outclk_0`. `outclk_1` is the same clock shifted 90° (20,345 ps) for `video_rgb_clock_90` |
| Horizontal | 512 total = 64 back porch + **384 active** + 64 front porch |
| Vertical | 400 total = 16 back porch + **216 active** + 168 front porch |
| Frame | 512 x 400 = 204,800 clocks |
| Refresh | 12,288,000 / 204,800 = **60.000 Hz** (the PLL really gives 12.287999 MHz, so 59.99999 Hz) |
| Sync | VS: 1 clock at x=0, y=0. HS: 1 clock at x=3 on every line. DE: high only in the 384x216 window. `video_skip` = 0 |

12.288 MHz is exactly 60 x 204,800. Any H_TOTAL x V_TOTAL that equals 204,800
therefore gives exactly 60 Hz from the PLL the template already ships. **No PLL
regeneration is needed**, and the clock names in `core_constraints.sdc` stay valid.
The long vertical blank is harmless: the Pocket's scaler only captures pixels
where DE is high. Later milestones will use the blank time for buffer flips.

### If you ever want a different pixel clock

Don't hand-edit the `mf_pllbase` files. They are generated, and the `.qip`, `.sip`,
`.spd` and `_0002.v` files must agree with each other. Change the clock in Quartus:

1. In the Project Navigator, choose **IP Components**, then double-click
   **mf_pllbase**. The PLL Intel FPGA IP parameter editor opens.
2. Keep reference clock 74.25 MHz and "Fractional-N PLL" mode. Set
   `outclk0` to the new frequency. Set `outclk1` to the same frequency with
   phase shift **90 degrees**. Leave `outclk2-4` as they are, or drop them,
   but then delete their lines from `core_constraints.sdc`.
3. Click **Generate HDL**, then **Finish**. Recompile.
4. Change `H_TOTAL`/`V_TOTAL` in `core_top.v` so that
   pixel clock / (H_TOTAL x V_TOTAL) is about 60 Hz.

## Step-by-step

### 1. Install the tools (once)

- **Intel Quartus Prime Lite Edition 25.1std** with **Cyclone V** device support (already on the dev PC).
- **Python 3.8+** from python.org. Tick "Add to PATH". No extra packages are needed.
- You do **not** need a RISC-V compiler: the firmware is already built into `src\fpga\core\fw\*.hex`.
  To change the firmware, see "Rebuilding the firmware" below.

### 2. Get the branch

```
git clone https://github.com/namdl0/core-template.git
cd core-template
git checkout ufo50-m3
```
(or `git fetch` and `git checkout ufo50-m3` in your existing clone)

### 3. Compile in Quartus

1. Start Quartus. Choose **File > Open Project** and select `src\fpga\ap_core.qpf`.
2. If a dialog offers to upgrade IP or the project's version, accept it.
3. Choose **Processing > Start Compilation** (Ctrl+L). Expect **15-40 minutes**: the CPU and FPU are much
   bigger than M1.
4. When it finishes, check and report back through the hub:
   - The Messages pane has **0 errors**. Warnings are expected (truncation warnings from the generated CPU,
     "no clock" warnings for the template's audio clock dividers, unconstrained-IO warnings).
   - **Compilation Report > Fitter > Resource Section > Resource Usage Summary**: note "Logic utilization (in
     ALMs)", "Total block memory bits", "Total RAM Blocks" and "Total DSP Blocks".
   - **Timing Analyzer > Slow 1100mV 85C Model > Setup Summary**: the clock
     `ic|mp2|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk` (57.75 MHz) must have a **positive slack**.
     If it is red (negative), send the slack and the first lines of "Report Top Failing Paths". The fix is then a
     lower clock (step 3a).
   - `src\fpga\output_files\ap_core.rbf` has a new timestamp (~1-2 MB).
   - Optional: **Compiler Report > Analysis & Synthesis > RAM Summary** should list the boot RAM
     (`bram0`..`bram3`, 8192 x 8 each) with an initialization file `boot_b0.hex`..`boot_b3.hex`. If Quartus
     warns that it cannot find a `.hex` file, the screen will stay on the M1 test pattern.

#### 3a. If timing fails at 57.75 MHz

In `src\fpga\core\core_top.v`, search for `SYS_FREQ_STR` and change both lines together, e.g. to

```
    localparam  SYS_FREQ_STR = "51.975000 MHz";
    localparam  SYS_FREQ_HZ  = 32'd51_975_000;
```
(other exact values: `"49.500000 MHz"` / `32'd49_500_000`). Recompile. Nothing else changes; the
firmware reads the clock from the hardware.

### 4. Package

From the repo root:

```
py tools\pocket_pack.py package
```

It validates the JSON files, bit-reverses `ap_core.rbf` into `Cores\namdl0.UFO50\bitstream.rbf_r`, writes the
SD tree to `build\sd\` and a zip `build\namdl0.UFO50_0.3.0_2026-10-25.zip`. Add `--sd E:\` to copy the
tree straight onto the SD card.

### 5. (Optional) a test file for the data-slot check

The hello test computes a CRC32 of the slot 0 file (`ufo50.gmp`) and re-reads its first 4 KB with target
command 0x0180. Any file works. To use a known file:

```
py tools\pocket_pack.py testfile E:\Assets\ufo50\common\ufo50.gmp --size 4M
```
It prints the CRC32 the screen should show. For an existing file, `py tools\pocket_pack.py crc <file>`.
Without a file the core still boots (all slots are optional).

### 6. Copy to the SD card

If you didn't use `--sd`, extract the zip onto the **root** of the Pocket's SD card:

```
E:\Cores\namdl0.UFO50\bitstream.rbf_r   (+ the .json files, icon.bin, info.txt)
E:\Platforms\ufo50.json
E:\Platforms\_images\ufo50.bin
E:\Assets\ufo50\common\ufo50.gmp         (optional, step 5)
```

### 7. What you should see on the Pocket (M3 exit test)

**openFPGA > UFO 50 > UFO50.** If you put a `ufo50.gmp` in place, the Pocket may first show a file
browser for it (choose it) and a short loading bar.

1. For a split second the **M1 test pattern** (colour bars), then a **dark blue screen with text**. If it stays
   on the colour bars, the CPU did not start: report it.
2. The text, top to bottom (numbers are examples):
   ```
   UFO50 Pocket SoC - M3 hello
   CPU  VexRiscv RV32IMFD  57.750 MHz
        I$ 16K 2-way  D$ 16K 2-way  FPU F+D      (ufo50-cache: I$ 64K 2-way  D$ 32K 2-way)
        measured 57.750 MHz (rdcycle 57.750)
   SLOT 0:4194304
        slot0 crc32 1A2B3C4D  1.30 s
        0x0180 read 4096 B: PASS
   SDRAM init PASS  bus PASS
        65024 KB march             PASS 12.3 s
   BW   wr xx.x MB/s rd xx.x MB/s
        cpy xx.x MB/s  sum ok
   FPU  sum 1/i^2 1.644924067  xx cyc/it
        fma 47581.313603 xx cyc  sqrt xx cyc
        double results PASS
   PERIPH blit PASS  mixer PASS
   ```
   - "measured" comes from counting clocks over 60 video frames: it must match the nominal clock.
   - With no file: `SLOT no files (all slots optional)` and `slot0: no file, CRC skipped`.
   - The SDRAM test covers all 63.5 MB below the framebuffers and takes several seconds; a progress counter
     runs at the right of its line. Any **FAIL** shows the failing address: report it.
   - A red line `TRAP mcause ... mepc ...` at the bottom means the CPU crashed: report the numbers.
3. At the bottom, a live area: `Frame N` counting at 60 per second, the `cont1_key` value, and the button
   names (UP DN LT RT A B X Y L1 R1 L2 R2 L3 R3 SE ST) highlighted in yellow while held, plus an orange block
   sliding smoothly left to right (cyan while A is held). Smooth motion without tearing shows the
   double-buffered framebuffer swap works.
4. **Dock:** the same at 16:9 on the TV. Audio: silence (the mixer is a stub).

Please report: everything on screen (a photo is ideal), the Quartus resource and timing numbers from step 3,
and the slot0 CRC versus the one `pocket_pack.py` printed.

### Troubleshooting

| Symptom | Likely cause |
|---|---|
| Core missing from the list | Folder isn't `Cores\namdl0.UFO50`, or `core.json` is invalid. Run `py tools\pocket_pack.py validate` |
| Pocket says it can't load the bitstream | `bitstream.rbf_r` isn't bit-reversed or is from a failed build. Repackage |
| Stays on the M1 colour bars | CPU not running: boot RAM `.hex` not found by Quartus (check warnings), or timing failure |
| Black screen | `reset_n` never released, or the PLL failed: check the compile had no errors |
| Text but garbled / wrong colours / SDRAM FAIL | SDRAM timing on the real board: report the screen and failing address |
| Picture shifted or edge cut off | Report which border colour is missing on which side (VID_CTRL test pattern) |

### Rebuilding the firmware (optional, Linux or WSL)

```
tools/fetch_rv32_toolchain.sh            # from the ufo50-ap repo: xPack riscv-none-elf-gcc 14.2.0-3
make -C firmware                         # writes src/fpga/core/fw/boot_b0..3.hex
```
Then recompile in Quartus (Quartus picks up the new `.hex` files; if it doesn't, use
**Processing > Update Memory Initialization File** and then **Processing > Start > Start Assembler**).

## Simulation (optional)

```
sh sim/run_sim.sh            # M1 video tests (Icarus Verilog)
sh sim/verilator/run.sh      # M3 SoC: firmware boots, draws the framebuffer, frames compared (Verilator 5)
```

`sim/verilator/run.sh` builds the `-DSIM` firmware (smaller tests), Verilates the SoC with the CPU, and runs it
with a cycle-based SDRAM model that checks SDRAM timing, an emulated APF (slot 0 loaded over the bridge
during reset, the data-slot size table, target commands 0x0180, 0x0184 and 0x0188 with the APF's bridge
reads of SDRAM checked word by word) and the real video timing. It writes the
displayed frames to `sim/out/vl_frame_NN.ppm` and compares every frame of the live loop pixel by pixel with the
framebuffer in SDRAM. It ends with `TB_SOC PASS` (the full hello run needs `+max_ms=1000`; `SDRAM_1X=1`
simulates the `SDRAM_2X = 0` controller the Pocket build uses; `+boot6=<image>` runs the slot-6 loader test). `sim/tb_soc.v` is the same test for Icarus Verilog
(`iverilog -g2012`), with a timing-accurate SDRAM model, but it runs at ~2k CPU cycles per second, so it only
gets through the boot in reasonable time.

## Data slots (`data.json`)

For M3 every slot is still `required: false`, so the core boots with no files. Slots with an `address` are
written by the APF over the bridge into SDRAM **before** the core leaves reset (the SDRAM controller and the
bridge path keep running during reset). Bridge address = CPU address (`docs/MEMORY_MAP.md`).

| id | name | file | mode |
|---|---|---|---|
| 0 | Program | `ufo50.gmp` | loaded to **0x10000000** (SDRAM), max 36 MB |
| 1 | Asset Index | `ufo50.gma` | loaded to **0x12400000**, max 4 MB |
| 2 | Texture Pack | `ufo50_tex.bin` | `deferload`: the CPU reads it with target command 0x0180 (`ds_read()`) |
| 3 | Audio Pack | `ufo50_snd.bin` | `deferload` |
| 4 | Text | `english.txt` | loaded to **0x12800000**, max 512 KB |
| 5, 7, 8 | Room Pack, Collision Masks, Paths | `ufo50_room.bin`, `ufo50.masks`, `ufo50.paths` | `deferload` |
| 6 | Runtime | `ufo50rt.bin` | loaded to **0x12880000**, max 1 MB |
| 10-12 | Save 1-3 | `save1.ufo` .. `save3.ufo` | **nonvolatile**, max 128 KB each, loaded to **0x13E40000 / 0x13E60000 / 0x13E80000** |
| 13 | Account | `account.ufo` | nonvolatile, max 64 KB, **0x13EA0000** |
| 14 | Config | `config.json` | nonvolatile, max 64 KB, **0x13EB0000** |

Asset files go in `/Assets/ufo50/common/` and saves in `/Saves/ufo50/common/`, the
platform-shared locations (parameters bit 1 is clear).

### Saves (branch `ufo50-saves`)

The nonvolatile slots work like every other openFPGA core's battery save: the APF loads the files that exist
in `/Saves/ufo50/common/` into SDRAM before the core starts, and when you **quit the core from the Pocket
menu, put the Pocket to sleep or power it off**, it reads each slot's region back over the bridge and writes
it to the card, with the size the core put in the data-slot size table. **No file has to exist beforehand**:
the first save creates `save1.ufo` etc. In addition the runtime issues target command 0x0184 (and 0x0188)
right after the game saves (debounced, ufo50-ap `runtime/pocket/saves.c`), so the card is current even if
the battery dies without a clean quit. Hardware side: `soc/bridge_sdram.v` serves the APF's bridge reads
from SDRAM, `soc/dataslot_ctrl.v` issues 0x0184/0x0188 and writes the size table (`docs/MEMORY_MAP.md` 3.2).
Nothing changes in the SDRAM clocking (`SDRAM_2X = 0`); compile, package and copy as for M5.

To check it on the Pocket: play until the game saves (profile selection writes `config.json`, playing a
game writes `save1.ufo`), quit the core through the Pocket menu, and look for the files in
`/Saves/ufo50/common/` on the card (they are the same format as the PC's `save/` files). Then start the
core again: the profile and progress are back. A save file copied from the PC version into that folder
is picked up too.
