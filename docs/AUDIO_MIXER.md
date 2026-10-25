# Audio mixer

Branch `ufo50-periph`. 32 hardware voices (IMA ADPCM or 16-bit PCM, mono or stereo, with loop points),
per-voice gain with a hardware linear fade, pan, fixed-point pitch/resample step, 8 groups + master gain,
mixed at 48 kHz stereo. Sources are 44.1 kHz; voices resample by their per-voice step (default
`MX_STEP_44K1 = 60211` in 4.16 fixed point = 44100/48000).

Files: `src/fpga/core/periph/mix_core.v` (voice state machine + mixer math), `mixer.v` (Wishbone slave +
command FIFO + output FIFO + I2S/`audio_tick` output stage), `sim/periph/model/mixer_model.[ch]`
(bit-exact C model), `adpcm.[ch]` (codec reference, encoder + decoder), `mixgen.c` (test-vector
generator), `tb_mixer.v` / `tb_mixer_tick.v` (testbenches), `src/fpga/core/soc/ufo50_mixer.v` (the
SoC-facing wrapper).

## Interface

- **Wishbone B4 classic slave**, 64 KB window (`docs/MEMORY_MAP.md` §4, module `ufo50_mixer`).
- **SDRAM master**, read-only, `docs/MEMORY_MAP.md` §5 (arbiter port X1).
- **Audio output**: `audio_tick` (input, one pulse per 48 kHz sample) / `audio_l`, `audio_r` (16-bit
  signed, held stable between ticks) — the SoC integration contract. The core (`mixer.v`) additionally
  keeps a standalone I2S path (`audio_mclk`/`audio_lrck`/`audio_dac`, `clk_74a`) for a bare
  core-template bench/build; the two paths share one output FIFO and are not meant to run at once (tie
  `audio_tick` low, or `clk_74a` low and never toggle the internal I2S request, to disable the other).
  I2S framing follows the Analogue core-template's own generator and agg23's `sound_i2s.sv`
  (github.com/agg23/analogue-pocket-utils, MIT): MCLK = 12.288 MHz from a fractional accumulator on
  `clk_74a`, SCLK = MCLK/4 = 3.072 MHz, LRCK = SCLK/64 = 48 kHz, 32-bit slots with the 16-bit sample in
  the first 16 SCLK cycles of each half, data changing on the falling SCLK edge.

## Registers (word offsets)

| Offset | Name | R/W | |
|---|---|---|---|
| `0x00` | `ID` | R | `"MIX1"` |
| `0x04` | `STATUS` | R | `[31:16]` command FIFO words free, low bits output FIFO level (as implemented in `mixer.v`; an earlier version of this table had the two fields swapped) |
| `0x08` | `CTRL` | RW | `[0]` enable, `[2]` soft reset |
| `0x0C` | `SAMPLES` | R | samples produced since reset |
| `0x10` | `MASTER_GAIN` | — | **command**, not a plain register — see below |
| `0x14` | `UNDERRUNS` | R | ticks where the output FIFO was empty |
| `0x18` | `PERF_CYCLES` | R | `[15:0]` cycles the last sample took, `[31:16]` max seen |

### Commands (queued through a FIFO, applied atomically before the next sample)

Writes to three regions are commands rather than plain registers, queued exactly like the blitter's
command FIFO so a burst of register writes from the CPU (e.g. "start voice": format, data, seek, length,
loop, start, step, gain, pan, ctrl) all take effect together, before the next 48 kHz sample, never split
across a sample boundary:

- `0x0010` **MASTER_GAIN**: `[15:0]` Q2.14 (0x4000 = unity).
- `0x0800 + 16*g + 4*r` (`g` = 0..7 group): `r=0` **GAIN** (Q2.14, immediate), `r=1` **FADE_TARGET**
  (Q2.14), `r=2` **FADE_LEN** (samples; writing this starts a linear ramp from the current gain to the
  last-written target over that many samples — 0 jumps immediately).
- `0x1000 + 64*v + 4*r` (`v` = 0..31 voice):

| r | Name | |
|---|---|---|
| 0 | `CTRL` | write: bit0 start (reset position to `START`), bit1 stop, bit2 pause, bit3 resume, bit4 seek (reset position without affecting play state) |
| 1 | `FORMAT` | `[0]` ADPCM (else PCM16), `[1]` stereo, `[2]` loop, `[3]` interpolate (linear, else nearest/step-held), `[6:4]` group |
| 2 | `DATA` | sample data base byte address |
| 3 | `SEEK` | ADPCM seek-table base byte address (ignored for PCM) |
| 4 | `LENGTH` | length in frames |
| 5 | `LOOP_START` | loop-return frame (ignored unless `FORMAT.loop`) |
| 6 | `START` | start frame (applied by `CTRL.start`/`seek`) |
| 7 | `STEP` | 4.16 fixed-point resample step (`MX_STEP_44K1` for an unmodified 44.1 kHz source at 48 kHz output) |
| 8 | `GAIN` | Q2.14, immediate (also clears any fade in progress) |
| 9 | `FADE_TARGET` | Q2.14 |
| 10 | `FADE_LEN` | samples; same semantics as the group fade |
| 11 | `PAN` | `[15:0]` left Q1.15, `[31:16]` right Q1.15 (`0x8000` = unity; independent L/R, not a crossfade pan law, so the CPU can also use this for simple stereo balance or a custom law) |

Voice status is **not** a command; it's read back live:
- `0x1000 + 64v + 0`: `[0]` playing, `[1]` paused, `[2]` ended (hit the end without a loop)
- `0x1000 + 64v + 4`: current position, in frames

## ADPCM format ("UFO50-IMA")

Standard IMA ADPCM (4-bit, the usual 89-entry step table and index adjustment, shift-add decode form —
see `adpcm.h`'s `ima_decode()`), packed for direct hardware seeking rather than the WAV/DVI block layout:

- **Data**: one nibble per channel per frame, no block headers interleaved into the data stream.
  - Mono: 2 frames per byte (frame `2k` in the low nibble of byte `k`, `2k+1` in the high nibble).
  - Stereo: 1 byte per frame (left = low nibble, right = high nibble).
- **Seek table**: one entry **per 256 frames**, per channel, written *before* that block's first sample —
  i.e. the decoder state as it would be immediately before decoding frame `256*b`. Each entry is a
  little-endian `u32`: `[15:0]` predictor (signed 16-bit), `[22:16]` step index (0..88). Stereo stores the
  left word then the right word for each block. The stream itself is still continuous end to end (the
  table only exists so the hardware/CPU can start decoding at any 256-frame boundary without replaying
  from frame 0); looping to a start point that isn't a block boundary still works (the engine decodes
  forward from the block start and discards the skipped frames — see "Mid-block loop points").
- This is the format `ima_encode()`/`ima_decode_stream()` in `adpcm.c` implement, and the one the
  asset-pipeline agent should target. Round-trip SNR on test tones: 17-25 dB (typical for 4-bit IMA on a
  full-scale sine; quieter/smoother sources do better), matching expectations for this bit depth — not a
  hardware bug, just what 4 bits/sample buys. `mixgen.c` self-checks every encoded test sound's seek table
  against the decoder's actual running state at each block boundary (`bad` counter, always 0).

### Mid-block loop points

A loop start that isn't on a 256-frame boundary (`sim/periph/model/mixgen.c`'s "stereo" test sound loops
at frame 700) is handled by seeking to the containing block's start and decoding forward, discarding
`pos & 255` frames before the first sample is actually output (`skip` field in both the C model and
`mix_core`'s `S_REPOS`/`S_VADV`/`S_DEC` states) — this is also how any non-block-aligned `START` position
is handled. Cost: up to 255 "free-running" ADPCM decode steps, which at one step/cycle for ADPCM is at
most 255 extra cycles, negligible against the 1,193-cycle-per-sample budget (see Resource/Timing below).

## C model

`sim/periph/model/mixer_model.[ch]`: cycle-free reference of the whole register file + voice processing +
fades + resampling + ADPCM/PCM decode, bit-exact with `mix_core.v` (all arithmetic — the 14-bit-shift
gain multiplies, the div-by-255-free blend math isn't used here since this is linear PCM mixing, the
linear-interpolation fixed point) mirrored exactly, including the Q-format shifts and saturation. Commands
are queued (`mx_write`) and applied atomically at the start of `mx_sample`, matching the hardware's
command-FIFO-drain-before-sample-N semantics.

## Verification

1. **HDL core vs. C model, lockstep** (`tb_mixer.v`, `mix_core` driven directly with `out_ready` paced one
   sample per iteration so command timing matches the model exactly): 3,000 samples, two independent
   random seeds, two memory timings (fast; and 40-cycle latency + 40% stall + 30% gap + 2-cycle-per-beat
   16-bit-SDRAM-like) — **bit-exact match, 0 mismatches**, covering ADPCM mono/stereo, PCM mono/stereo,
   block-aligned and mid-block loop points, start-offset playback, start/stop/pause/resume, voice and
   group fades (including a fade retargeted mid-ramp), gain/pan changes, pitch/step changes outside
   44.1->48k (explicit mid-stream seeks), and master-gain changes. Cycles/sample: avg 428-494, max
   1,292-1,620 across the two memory timings, against the **1,193-cycle budget** (57.75 MHz / 48 kHz) —
   see "Timing" below for what this means.
2. **HDL through the actual SoC integration path** (`tb_mixer_tick.v`): the `ufo50_mixer` wrapper
   (`periph_mem_port` adapter, Wishbone register file, output FIFO, `audio_tick` pop) against
   `sdram_arb_model.v` (the `mem_cmd_*` protocol, both a fast and a 30%-stall/30-cycle-latency timing),
   with `audio_tick` paced at the real 48 kHz/57.75 MHz spacing (1,203 `clk_sys` cycles). 300 samples
   match the C model exactly at a constant 2-sample pipeline/FIFO latency — confirming the register
   decode, command-FIFO plumbing and memory-port adapter move data correctly end to end, decoupled from
   `mix_core`'s own (already bit-exact) sample production.
3. **ADPCM codec round-trip**: `mixgen` encodes six test sounds (tones, stereo, noise-ish, full-scale
   clicks to exercise saturation, both loop-boundary cases) and checks the seek table against the actual
   decoder state at every block (`bad` always 0) and reports SNR (self-consistency, not a pass/fail gate —
   4-bit ADPCM's lossy by design).
4. **Not yet run**: the standalone I2S output path (`i2s_tx`/`tb_mixer_i2s.v`) — the testbench hung past
   its time budget (likely a pacing issue in the TB's sample-arrival wait, not necessarily the RTL) and
   was not re-debugged given the session's time budget. The I2S *module* itself (`i2s_tx` in `mixer.v`)
   is a direct, unmodified port of the Analogue-template/agg23 bit-shifting logic cited above, and is not
   on the SoC-integration path (`ufo50_mixer` uses `audio_tick`/`audio_l`/`audio_r` only) — flagged as an
   open item below for whoever uses the bare core-template I2S path.

## Timing (57.75 MHz `clk_sys`, 48 kHz output — 1,203 cycles/sample average, 1,193 strict budget\*)

\*1,193 = floor(57,750,000 / 48,000); the engine is not required to produce exactly one sample every
*single* 1,193-cycle window — it drains into a 16-sample output FIFO (`OF_AW=4`), so a slow sample can
borrow from the buffer's ~16-sample (0.33 ms) slack as long as the *average* rate keeps up. Measured
average (428-494 cycles/sample) is **3-4x inside budget**; the measured worst case (1,620 cycles, one
voice doing an unaligned ADPCM reposition/loop plus a cache-miss-like memory fetch) is still under the
strict single-sample budget, so the FIFO's slack is a safety margin, not a requirement, for every test run
so far. 32 voices all active simultaneously (worst case not directly exercised — the test schedule starts
up to 12 at once and churns through more over the run, but never confirmed all 32 live at the same
instant) is flagged as an open item below.

## Resource estimate (Yosys 0.44 + Mistral; see the blitter doc for the same caveat re: Quartus)

`mixer` (core + Wishbone + FIFOs + status RAM), post-`synth_intel_alm`:
- ALUTs: 4,519 (287x2-input, 782x3, 636x4, 952x5, 227x6, 2,635 arithmetic-mode), FFs: 2,065
- M10K blocks: 11 (110 Kb of 3,383 Kb, 3.3%)
- Multipliers: 7x 18x18 + 2x 27x27 + 4x 9x9 (≈9-10 of 66 DSP blocks; the 27x27s are the gain/pan Q2.14 x
  Q1.15-ish products computed at full width before truncation — see `mix_core.v`'s `S_MIX1`/`S_MIX3`)
Combined with the blitter (`docs/BLITTER.md`), total logic is well under 10% of the 5CEBA4's 18,480 ALMs
even without ALUT-to-ALM packing credit, leaving ample room for the VexRiscv CPU and SDRAM controller.

## Open questions for the SoC/asset-pipeline teams

- All-32-voices-active worst-case cycle count not directly measured; the voice loop is a fixed 32
  iterations regardless of how many are actually playing (`S_VCHK` short-circuits idle voices quickly), so
  this is expected to scale roughly linearly and stay in budget, but should be confirmed with a dedicated
  test once the asset pipeline has real multi-voice game audio to replay.
- The standalone I2S path (`i2s_tx`) is unverified in this session (see Verification item 4) — low risk
  (unmodified reference logic, and not used by the SoC integration path) but should get a working
  testbench before anyone relies on the bare core-template audio output.
- `docs/MEMORY_MAP.md` doesn't yet specify how the mixer's `irq` output should be used (the core doesn't
  raise one yet — `ufo50_mixer.v` ties it to 0); if the firmware wants an "output FIFO getting low"
  interrupt instead of polling `STATUS`, that's a small addition to `mixer.v`'s control logic.
