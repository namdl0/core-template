# Blitter

Branch `ufo50-periph`. Executes the runtime's display list (`RenderCmd`, `ufo50-ap/runtime/src/rt.h`)
from 8 bpp indexed texture pages with a per-page 256-entry palette. Implements `RC_BLIT`, `RC_FILL`,
`RC_CLEAR` and `RC_BLIT_MAP` (scaled blits as a destination rect plus per-column/row texel-index tables).
Rotation stays in software, as in the PC runtime.

Files: `src/fpga/core/periph/blit_engine.v` (row-pipelined executor, drives the SoC's SDRAM master
port directly since branch `ufo50-blit2`), `blitter.v` (Wishbone slave + command FIFO), `periph_ram.v`
(RAM/FIFO primitives), `sim/periph/model/blit_model.[ch]` (bit-exact C model),
`sim/periph/tb_blitter_soc.v` + `sdram_arb_model.v` (random-stream testbench, `run_blit_vl.sh`),
`sim/periph/model/blitgen.c` (test-vector / dump-replay generator), `src/fpga/core/soc/ufo50_blitter.v`
(the SoC-facing wrapper named per the memory map contract). `periph_mem_port.v` is now used by the mixer
only. `tb_blitter.v`/`run_blit.sh` (Icarus, the old internal port) are kept for history and no longer
match `blitter.v`'s ports.

## Interface

- **Wishbone B4 classic slave**, 64 KB window (`docs/MEMORY_MAP.md` §4, module `ufo50_blitter`).
- **SDRAM master**, read and write, `docs/MEMORY_MAP.md` §5 (arbiter port X0).
- `irq`: level, mirrors a pending fence interrupt (see below).

### Registers (word offsets from the window base)

| Offset | Name | R/W | |
|---|---|---|---|
| `0x00` | `ID` | R | `"BLT1"` (0x424C_5431) |
| `0x04` | `STATUS` | R | `[31:16]` command FIFO words free, `[2]` FIFO empty, `[1]` IRQ pending, `[0]` busy (as implemented in `blitter.v`; an earlier version of this table had the fields at the wrong bits) |
| `0x08` | `CTRL` | RW | `[0]` IRQ enable, `[1]` palette-cache flush (self-clearing), `[2]` soft reset (self-clearing) |
| `0x0C` | `FENCE` | R | value of the last executed `FENCE` command |
| `0x10` | `IRQ_ACK` | W | write 1 to clear the pending IRQ |
| `0x14` | `PERF_BUSY` | R | cycles busy since reset/soft-reset |
| `0x18` | `PERF_PIXELS` | R | pixels actually written (mask set) since reset; a `CLEAR` dropped by CLEAR coalescing (see Pipeline) is not counted |
| `0x1C` | `PERF_MEMWAIT` | R | cycles stalled waiting for the SDRAM master port |

Writes to `0x8000-0xFFFF` (or word `0x0040`, same alias) push one 32-bit word into the command FIFO.
Commands are 8 words; the CPU writes all 8 before the engine starts on it. `STATUS` word count lets the
CPU avoid blocking on a full FIFO.

## Command format (8 x 32-bit words)

| Word | Bits | Field |
|---|---|---|
| 0 | `[3:0]` | op: 0 BLIT, 1 FILL, 2 CLEAR, 3 BLIT_MAP, 4 SET_DST, 5 SET_TEX, 6 FENCE |
| | `[4]` | flip X |
| | `[5]` | flip Y |
| | `[7:6]` | blend: 0/2 normal, 1 add, 3 subtract |
| | `[8]` | fog (replace RGB with `colour`, keep tinting off) |
| | `[9]` | (FENCE) raise IRQ |
| | `[10]` | (SET_TEX) force palette reload even if the tag matches a cached entry |
| 1 | `[15:0]`/`[31:16]` | dst x / dst y (BLIT/FILL/CLEAR/MAP); (SET_DST) destination base byte address |
| 2 | `[15:0]`/`[31:16]` | width / height; (SET_DST/SET_TEX) `[15:0]` = row stride in bytes |
| 3 | `[15:0]`/`[31:16]` | src x / src y (page-relative); (SET_TEX) palette base byte address |
| 4 | `[23:0]` | tint/fog colour (BGR); (CLEAR) full 32-bit raw value incl. alpha |
| 5 | see below | alpha word |
| 6 | | (BLIT_MAP only) address of the `mapx` table (int32 per destination column, `-1` = skip) |
| 7 | | (BLIT_MAP only) address of the `mapy` table (int32 per destination row) |

`SET_DST`/`SET_TEX` persist until the next one; a command stream is typically `SET_DST, SET_TEX, {draws},
SET_TEX, {draws}, ..., FENCE`. The engine caches the last 4 distinct palettes by their base address
(`tag`), so re-selecting a recently used page's palette costs nothing; a palette that was DMA'd into a new
buffer at the *same* address must set bit `[10]` of word 0 to force a reload (or the CPU issues the
palette-flush control bit after any in-place edit).

### Alpha word (word 5)

Hardware alpha is 8 bit; the runtime's software path computes `a' = (uint)(src_alpha * alpha + 0.5)` in
double precision. To stay bit-exact, the CPU does not just round `alpha * 65536`: it picks a 16.16
multiplier `a16` such that `(src_alpha * a16 + 0x8000) >> 16` reproduces the exact software rounding for
*every alpha level that page's palette actually uses* (there are at most ~10 per page in the shipped
textures; see "Texture pages" below). `bm_alpha_word()` in `blit_model.h` is the reference
implementation and is exhaustively checked (`test_blit_unit.c`) against every single-level case and
fuzzed against the runtime's `blend_px`/`tint_c` over 3,000,000 random pixels with zero mismatches.

| Bits | Field |
|---|---|
| `[7:0]` | `a255 = (uint)(255 * alpha + 0.5)`, used only when the source alpha is already 255 (opaque texel; this is the one case `bm_alpha_word` can always satisfy exactly) |
| `[8]` | 1 if `alpha < 1` (bit clear means "alpha == 1", skip the multiply) |
| `[31:16]` | `a16`, the 16.16 multiplier for non-opaque source alpha |

Hardware result: `sa = (ta == 255) ? a255 : (ta * a16 + 0x8000) >> 16`. For `alpha <= 0` the word is all
zero (nothing is drawn, matching `alpha<0` being treated as 0 by the reference's unsigned cast — see
"Known divergence" below).

### Known divergence from the software path

- `alpha < 0`: the PC software path casts a negative double to `uint32_t`, which is undefined behaviour in
  C and in practice produces a huge wrapped value (effectively opaque) on x86. The hardware instead treats
  any `alpha <= 0` as fully transparent (nothing drawn). GML code is not expected to pass a negative alpha;
  this is documented, not matched, because matching undefined behaviour isn't meaningful.
- Beyond that, **zero** pixel differences were found against the real runtime over 1.16 billion checked
  pixels (library + Barbuta, every submitted command, `UFO_BLIT=check`) and over three independent 300-900
  command random fuzz runs against the hardware RTL in simulation (`run_blit.sh`). See Verification.

## Texture pages

Checked directly on the shipped `data.win` (`tools/gmassets.py` output, `build/texcache/*.rgba`, 106
pages): **every page uses ≤ 243 distinct colours including the fully-transparent entry** (max seen: 243),
so 8 bpp indexed + 256-entry palette is lossless for the whole game, matching `docs/RV32_MEASURE.md`'s
"≤242 unique per page" figure. At most 10 distinct non-opaque, non-zero alpha levels appear on any single
page (`tex4.rgba`), which is what the alpha-word solver above has to satisfy simultaneously — it always
can (`bm_alpha_word`'s 20,000-random-9-level-set test found an inexact case for only 1 in 20,000 sets,
and every one of the real 106 pages is exact). Page sizes seen: up to 2048x2048 (4M texels); the hardware
only limits a single command's *destination* width (512 px) and a `BLIT_MAP`'s row count (1024) and
source span (2044 texels) — see "Hardware limits".

## Hardware limits (handled by the runtime backend's `bm_submit`, not by the engine)

- **Destination width** per command ≤ 512 px (`BM_MAX_W`): wider commands are split into ≤512-px strips.
- **`BLIT_MAP` row count** ≤ 1024 (`BM_MAX_MAP_H`): taller maps are split into ≤1024-row strips.
- **`BLIT_MAP` source span** (max(mapx) - min(mapx) + 1) ≤ 2044 texels (`BM_MAX_SPAN`, one row's line
  buffer): a map whose columns span more of the page than that falls back to software (`st_fallback`
  counter; did not occur once in the dumped Barbuta/library frames or the 17,000-frame full-run check).
- A page with more than 256 colours (shouldn't occur; checked above) also falls back to software.
Splitting is transparent to the runtime: `rc_submit` always calls `bm_submit`, which recurses before
calling the model/hardware path, so the display list's contract to the rest of the engine is unchanged.

## Pipeline (`blit_engine.v`)

Three overlapped per-row stages, so SDRAM latency for row *N+1* hides behind compute/write of row *N*:
- **fetch**: issues the source-texel burst (and, when the result can depend on it, the destination-pixel
  burst) for one row into a double-buffered line cache (`srcbuf`/`dstbuf`, 2 x 512 words each).
- **compute**: an 8-stage pipeline, 1 pixel/clock: byte index -> palette lookup -> tint/fog -> source alpha
  (opaque fast path or the `a16` multiply) -> blend (normal/add/subtract) with a per-pixel write mask,
  into `outbuf` (2 x 512 slots).
- **write**: masked write bursts over the row's written pixels, one per *segment* (below).
Four palettes are cached in BRAM, round-robin on `SET_TEX`, hit-checked by base address so back-to-back
draws from the same page cost nothing extra.

The 16-bit SDRAM moves one 32-bit word every 2 clocks, so the engine (1 pixel/clock) is bound by memory
traffic, not by compute: a written pixel costs 2 clocks of bus time, a destination read 2 more, a source
texel 0.5, plus ~7-9 clocks per access (ACTIVE/precharge, controller turnaround). Branch `ufo50-blit2`
(measured with `BLIT_PROF`, see Verification) cuts that traffic and the idle time between accesses:

1. **Direct SDRAM port.** The engine is the arbiter port X0 master itself (`s_cmd_*`): a write access
   is presented as soon as the first beats of the row are in a 3-entry skid buffer fed from `outbuf` at
   1 word/clock (the old `periph_mem_port` copied every 32-word block into a staging buffer first, leaving
   the bus idle meanwhile), and every access is cut only at 64 beats and at 2 KB SDRAM-row boundaries
   (was: 128-byte blocks).
2. **Destination reads only where needed.** A normal-blend, alpha-1 `BLIT`/`BLIT_MAP` used to read the
   whole destination rectangle whenever the page's palette had *any* translucent entry. Its result can
   only depend on the destination for texels whose palette alpha is translucent (0 < a < 255: a=255
   replaces, a=0 is not written), so each fetched source row is scanned as it arrives against the current
   palette's 256-bit translucency map (`partram`, 4 x 256 bits, filled while a palette loads, copied to
   `part_cur` in 8 cycles on a palette-cache hit) and the destination row is fetched only if one of its
   bytes hits (the scan covers the whole fetched span, a superset of the texels used, so it can only err
   towards an unneeded read). Add/subtract/alpha<1 commands keep the full read. In every captured game
   frame no draw needed a destination read at all; before, 20-40% of the bus time was these reads.
3. **Write segments.** While a row is computed its written pixels are recorded as segments
   (`segram`, 2 x 256 x {start,end}); a run of 5 or more unwritten pixels (transparent texels,
   `BLIT_MAP` skips) ends one write access and starts another, instead of being sent with all byte
   enables off at 2 clocks per pixel.
4. **CLEAR coalescing.** A `CLEAR` is held back until the next command is decoded. If that is a `CLEAR`
   of the same rectangle (words 1-2 equal) with no command in between - so on the same surface - the held
   one is dropped: all its pixels would be overwritten. Any other command (including `SET_DST` and
   `FENCE`), or 256 idle cycles with an empty command FIFO, executes the held `CLEAR` first and then the
   command; `STATUS.busy` stays 1 while one is held. Valbrace and Hyper Contender clear the full screen
   twice per frame (one full-screen `CLEAR` is ~170k cycles). The output is identical; only `PERF_PIXELS`
   and the timing change.

## Verification

1. **C model vs. the runtime's `rc_exec`** (bit-exact, pixel by pixel): `UFO_BLIT=check` in the runtime
   (`ufo50-ap` branch `blit-model`, `make blitmodel`) runs every submitted command through both and
   compares. Over the library (3,000 frames), Barbuta (5,000 frames) and a 9,000-frame random-input
   session: **0 of 1,935,571,970 checked pixels differ**, including 2,000 `BLIT_MAP` commands and 1,100
   fractional-alpha commands. Full-run `--fbhash` is also byte-identical with the model *replacing*
   `rc_exec` (`UFO_BLIT=model`) over the same three runs (17,000 frames total) against the unmodified
   runtime.
2. **HDL vs. the same C model**: `sim/periph/run_blit.sh` (Icarus Verilog 12, `tools/iv`) — three random
   300/900-command streams against a behavioural SDRAM model (`sdram_model.v`) at three timings (fast,
   30% stall + 30% gap + 20-cycle latency + 16-beat bursts, and 16-bit-SDRAM-like 2-cycles/beat) — plus
   two **real captured frames** (one full Barbuta frame via `UFO_DLDUMP`, one full library frame
   including its scaled `BLIT_MAP` blits) replayed byte-for-byte against the HDL output, at both the fast
   and the 16-bit-SDRAM timing. All PASS (`out.hex == expect.hex`, exact).
3. **HDL through the actual SoC memory-port protocol**: `tb_blitter_soc.v` instantiates the
   `ufo50_blitter` wrapper (the `periph_mem_port` adapter included) against `sdram_arb_model.v`, a
   behavioural model of `docs/MEMORY_MAP.md` §5's `mem_cmd_*` handshake (one outstanding command, ≤8
   beats, write data pulled via `wready`). Same random and real-frame vectors; all PASS.
4. `make blitmodel` in the runtime adds no change to the normal (`make ufo50rt`) build — the hook is
   `#ifdef BLIT_MODEL` only in `render.c`'s `rc_submit`/`put_px`/`render_frame`.
5. **Branch `ufo50-blit2`** (the engine as described above), all with Verilator 5.034:
   - `sh sim/periph/run_blit_vl.sh`: `tb_blitter_soc.v` against `sdram_arb_model.v` (now: 64-beat
     commands, a 2 KB-row check, random command stalls, latency and beat gaps including back-to-back
     `wready`), four random streams (300-900 draws; flips, tint, fog, alpha < 1, add/subtract,
     `BLIT_MAP` with skips, `FILL`, `CLEAR` incl. same-rectangle chains, a palette with only two
     translucent entries so rows with and without a destination read mix): **4/4 PASS** (HDL == C model).
     A deliberately broken CLEAR-coalescing compare is caught (FAIL).
   - SoC benches (`firmware/bench`, `SDRAM_1X=1`): the eight frames of the Throughput table, bit-exact,
     SDRAM model 0 timing errors; also on the 115.5 MHz `sdram_ctrl2x` build.
   - `SDRAM_1X=1 sh sim/verilator/run.sh +max_ms=1000`: TB_SOC PASS, `BLIT 11 cmds vs C model PASS`
     (43,849 cycles, was 50,277), 37 frames compared with 0 mismatches, save write-back test PASS, SDRAM
     model 0 errors; `+boot6=` PASS; `make benchmix` 0 mixer underruns under blitter load.

## Throughput (branch `ufo50-blit2`, real frames on the full SoC, `SDRAM_2X = 0`)

`firmware/bench` replays a captured command stream on the Verilator SoC (`SDRAM_1X=1`, the controller the
Pocket build uses) while the video scans the destination out as ABGR8888, and compares the destination
with the C model word for word. Frames: `barb`/`lib` are the earlier PC-runtime dumps (2 frames each);
the six games are one frame each of the Pocket image itself (`ufo50-ap` main, `rv32sim --soc` with the
`tools/rv32sim-bdump.patch` capture, the 50-game survey's input scripts, median-blitter frames of the
gameplay window). Busy = `PERF_BUSY` cycles; free = busy minus the cycles another master (the video)
owned the SDRAM, i.e. the blitter's time without contention (the bench's short runs see a variable share
of scanout, so free is the fairer before/after number). Every run bit-exact, 0 SDRAM timing errors.

| frame | draws | busy before | busy after | free before | free after | free change |
|---|---|---|---|---|---|---|
| Barbuta (2 frames) | 530 | 1,418,879 | 1,241,452 | 1,227,817 | 1,056,049 | -14% |
| library (2 frames) | 170 | 1,536,539 | 1,293,505 | 1,314,045 | 1,116,057 | -15% |
| Valbrace f5416 | 25 | 940,453 | 306,194 | 772,165 | 305,138 | -60% |
| Hyper Contender f4214 | 219 | 1,692,461 | 826,744 | 1,415,991 | 691,778 | -51% |
| Overbold f4019 | 488 | 1,204,686 | 687,268 | 1,019,032 | 592,466 | -42% |
| Avianos f4389 | 143 | 1,766,933 | 937,216 | 1,466,001 | 765,728 | -48% |
| Vainger f4002 | 201 | 1,819,735 | 1,186,337 | 1,500,257 | 1,006,755 | -33% |
| Quibble Race f4077 | 377 | 1,000,739 | 561,414 | 816,691 | 510,026 | -38% |

In a game the scanout takes ~18% of the SDRAM time over a frame (216 lines x 6 x 135 cycles of 962,500),
so a frame's blitter time is about free / 0.82: Valbrace 0.94M -> 0.37M cycles, Hyper Contender 1.73M ->
0.85M, Overbold 1.25M -> 0.72M, Avianos 1.79M -> 0.94M, Vainger 1.83M -> 1.23M, Quibble Race 1.00M ->
0.62M (budget 0.96M per 60 Hz frame). Barbuta and the library gain least: they never read the
destination and draw 16-px tiles, so they were already close to the write-traffic floor.

Where the remaining time goes (`BLIT_PROF`, Hyper Contender after): 82% SDRAM data beats, 9% waiting
for the controller between accesses (its fixed ACTIVE/precharge turnaround, `sdram_ctrl.v` S_WAIT, and
refresh), 4% bus idle between commands, the rest ACTIVE/tRCD inside accesses. The next levers, not done
here: overlapping a write's precharge with the next access's ACTIVE in another bank in `sdram_ctrl.v`
(~4-6%, touches the controller every master uses), and starting the next command's first fetch while
the previous one's last rows are written (~3-5%).

### Profiling and capture

- `BLIT_PROF=1 SDRAM_1X=1 sh sim/verilator/run.sh ...` builds the SoC with `blit_engine.v`'s
  simulation-only counters (`ifdef BLIT_PROF`, not synthesised): cycles per engine state, port waits,
  compute stalls, SDRAM ownership and the reason for every idle bus cycle while the blitter is busy,
  printed at the bench's final `FENCE 0xD0D0`.
- Capturing a Pocket frame: apply `tools/rv32sim-bdump.patch` to `ufo50-ap` (`git apply`, then
  `make -C tools/rv32sim`), run the survey command line (`tools/pocket_survey.py`'s `sim_cmd`, with the
  game's `input.txt`) plus `--bdump N:DIR --stop-after N+2`. DIR gets the regions the frame's commands
  touch at their real SDRAM offsets (snapshot before the frame's first command executes), `hdr.le`,
  `expect.le` (C model on the snapshot; the tool also reports that it equals the simulator's own result)
  and `preload.txt`. Run: `make -C firmware bench`, copy `firmware/build/bench/boot_b*.hex` to
  `<dir>/sim/fw/`, then from `<dir>`: `<repo>/sim/out/vl_obj_1x/Vvl_top +max_ms=400 $(cat DIR/preload.txt)`
  (`BENCH 12/13` = busy hi/lo, `BENCH 01` = mismatching words, must be 0).

## Resource estimate

Earlier figure (Yosys 0.44 + Mistral, `ufo50-periph`): `blitter` ~2,974 ALUTs, 2,238 FFs, 22 M10K,
130 MLAB, ~6 DSP. `ufo50-blit2` changes (no Yosys/Quartus here, estimated by hand):
- removed from the blitter: `periph_mem_port` (64 x 36-bit staging RAM, read/write chunkers), roughly
  150-250 ALMs and 2-4 MLABs;
- added: `segram` 512 x 18 (1 M10K), `partram` 32 x 32 (1 MLAB or M10K), `part_cur` 256 FFs with 8 word
  enables, the source-row scan (four 256:1 bit muxes, ~340 ALUTs), segment tracking (~60 ALMs), CLEAR
  coalescing (3 x 32-bit registers, two 32-bit compares, ~60 ALMs), 2 KB-row access cutting (~30 ALMs).
- net: about +400-600 ALMs (~2-3% of the 5CEBA4's 18,480) and +1-2 M10K. Timing: the new paths are short
  (the scan is register -> 3-level mux -> OR -> register; the access-length cut is a 10-bit subtract and
  two compares before a register); the longest new combinational path is the arbiter's `wready` into the
  skid-buffer refill condition and `outbuf`'s read address (controller state -> arbiter AND/owner compare ->
  3-bit add/compare -> RAM address), about 5-6 LUT levels.

## C model and test-vector generator

`sim/periph/model/blit_model.[ch]`: cycle-free reference, same source vendored into the runtime at
`ufo50-ap/runtime/src/hw/` (branch `blit-model`) via `blit_rt.c`. `test_blit_unit.c` checks the datapath
(`bm_div255`, `bm_alpha_word`, the full per-pixel path) against copies of the runtime's `blend_px`/
`tint_c`, fuzzed. `blitgen.c` builds HDL test vectors two ways: `random` (synthetic pages/palettes/
commands) and `dump` (replays a runtime `UFO_DLDUMP` capture, cropping each referenced texture page to
its used bounding box so the generated memory image stays small). `bm_run_mem()` is a byte-exact model of
the *hardware's* command-stream execution (palettes/tables read from memory by address, not passed as
pointers), used to produce `expect.hex`.

## Open questions for the SoC team

- The library's worst-case ~276k-texel frame (not captured in the dumped sample) should be measured
  directly once `ufo50-m3`'s firmware can drive the blitter from a real room, to confirm the ~40 ms
  16-bit-timing extrapolation above isn't actually hit under the real arbiter's video/CPU contention.
- The blitter now issues up to 64-beat accesses (as the video already did), so another master can wait
  up to ~135 cycles behind one (was ~71 with 32-beat blocks). The mixer stress bench (`make benchmix`,
  32 voices while Hyper Contender's frame is replayed 3 times) shows 0 underruns, as before.
- `FENCE`'s IRQ is wired but the firmware side (clearing `IRQ_PENDING` bit 2) is the SoC/firmware team's
  to exercise; only polling (`STATUS` bit 1 / `IRQ_ACK`) was tested here.
