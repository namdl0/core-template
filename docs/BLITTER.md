# Blitter

Branch `ufo50-periph`. Executes the runtime's display list (`RenderCmd`, `ufo50-ap/runtime/src/rt.h`)
from 8 bpp indexed texture pages with a per-page 256-entry palette. Implements `RC_BLIT`, `RC_FILL`,
`RC_CLEAR` and `RC_BLIT_MAP` (scaled blits as a destination rect plus per-column/row texel-index tables).
Rotation stays in software, as in the PC runtime.

Files: `src/fpga/core/periph/blit_engine.v` (row-pipelined executor), `blitter.v` (Wishbone slave +
command FIFO), `periph_ram.v` (RAM/FIFO primitives), `periph_mem_port.v` (adapter to the SoC's SDRAM
master port, `docs/MEMORY_MAP.md` §5), `sim/periph/model/blit_model.[ch]` (bit-exact C model),
`sim/periph/{tb_blitter,tb_blitter_soc}.v` (testbenches), `sim/periph/model/blitgen.c` (test-vector /
dump-replay generator), `src/fpga/core/soc/ufo50_blitter.v` (the SoC-facing wrapper named per the memory
map contract).

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
| `0x18` | `PERF_PIXELS` | R | pixels actually written (mask set) since reset |
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
- **fetch**: issues the source-texel burst (and, when blending/alpha/palette-translucency requires it,
  the destination-pixel burst) for one row into a double-buffered line cache (`srcbuf`/`dstbuf`, 2 x 512
  words each).
- **compute**: an 8-stage pipeline, 1 pixel/clock: byte index -> palette lookup -> tint/fog -> source alpha
  (opaque fast path or the `a16` multiply) -> blend (normal/add/subtract) with a per-pixel write mask,
  into `outbuf` (2 x 512 slots).
- **write**: one masked write burst per row (coalesced to the pixels actually touched by `BLIT_MAP`'s skip
  entries), split at the memory port's burst limit.
Four palettes are cached in BRAM, round-robin on `SET_TEX`, hit-checked by base address so back-to-back
draws from the same page cost nothing extra. The destination burst is skipped entirely (and its RAM input
force-zeroed, see "Verification") whenever the command is opaque/normal-blend with alpha==1 and an opaque
palette — most of Barbuta's tile and sprite blits.

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

## Throughput estimate (57.75 MHz `clk_sys`, `docs/MEMORY_MAP.md`)

From the captured real frames (`run_blit.sh`'s `DUMPS` step, `perf_busy`/`perf_pixels`):
- **Barbuta**: 265 draw commands/frame, 73,248 texels touched, 82,944 pixels actually written (opaque
  tile layer dominates; most commands skip the destination read). HDL: 275,690 busy cycles with the fast
  memory timing (**4.8 ms** at 57.75 MHz), 620,401 cycles (**10.7 ms**) at the 16-bit/2-cycle timing.
- **Library** (5 of its ~20 scaled-blit frames): 126 commands, 111,748 pixels written including the
  `BLIT_MAP` strips. 364,513 busy cycles fast (**6.3 ms**), 931,474 (**16.1 ms**) at 16-bit timing.
- Both are well under the 16.67 ms frame budget even at the pessimistic memory timing, with ~50% of a
  frame left for the CPU and audio, matching `docs/CORE_PREP.md`'s "takes ~70% of the frame cost" offload
  target being more than met. The 16-bit timing figure is conservative: the real SDRAM is interleaved by
  the arbiter across video/CPU/audio and bursts up to 32 B (8 beats), close to the fast-timing numbers
  above (~8 cycles + 2/beat per `docs/MEMORY_MAP.md` §5, vs. this estimate's 20-cycle latency + 16-beat
  worst case).
- The library's full ~276k-texel/frame worst case (`docs/RV32_MEASURE.md`) is ~2.5x the measured 5-frame
  average above; scaling linearly stays under budget (~16 ms fast-memory, ~40 ms 16-bit — the latter would
  need the SoC team's real arbiter numbers to confirm, flagged as an open question below).

## Resource estimate (Yosys 0.44 + Mistral, Cyclone V primitives; Quartus not available here — see
`docs/CORE_PREP.md` for the toolchain note)

`blitter` (engine + Wishbone + FIFOs + RAMs), post-`synth_intel_alm`, pre-placement:
- ALUTs: 2,974 (228x2-input, 485x3, 359x4, 534x5, 209x6, 1,159 arithmetic-mode), FFs: 2,238
- M10K blocks: 22 (220 Kb of 3,383 Kb available, 6.5%); MLAB: 130 (small FIFOs/skid buffers)
- Multipliers: 2x 18x18 + 16x 9x9 (≈6 of 66 DSP blocks)
These are LUT/FF primitive counts from an open-source synthesis flow, not Quartus's ALM-packed LE count;
expect Quartus to report somewhat fewer ALMs than this ALUT count (Cyclone V ALMs pack two LUTs under
shared inputs) but the figure is a reasonable upper bound. Logic is ~6% of the 5CEBA4 budget of 18,480
ALMs even without packing credit.

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
- `periph_mem_port` currently assumes the write-staging buffers (2 x 8 words) can always drain before the
  next 32-byte block is ready; under heavy arbiter contention (video scanout + CPU) this could in
  principle stall the collecting side. Not observed in simulation (fixed-latency and 30%-stall models),
  but the real arbiter's worst-case latency bound (`docs/MEMORY_MAP.md` says "below 256 cycles") is wider
  than tested here.
- `FENCE`'s IRQ is wired but the firmware side (clearing `IRQ_PENDING` bit 2) is the SoC/firmware team's
  to exercise; only polling (`STATUS` bit 1 / `IRQ_ACK`) was tested here.
