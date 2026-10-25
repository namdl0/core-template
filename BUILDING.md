# Building the UFO 50 Pocket core (milestone M1)

This branch (`ufo50-m1`) turns Analogue's core template into the first stage of the
UFO 50 port: a core called **UFO50** by **namdl0** that boots on the Analogue Pocket
and shows a 384x216, 16:9 test pattern at 60 Hz. No game files are needed yet.

The steps below assume Windows. Linux works the same way. Use `python3` instead
of `py`, and `/media/...` instead of `E:\`.

## What's in the branch

| Path | What it is |
|---|---|
| `src/fpga/ap_core.qpf` | Quartus project (Cyclone V 5CEBA4F23C8) |
| `src/fpga/core/core_top.v` | Template top level. The video section now instantiates `ufo50_video` |
| `src/fpga/core/ufo50_video.v` | **New**: 384x216 timing generator and test pattern |
| `src/fpga/core/core_bridge_cmd.v` | Template host/target command handler (unchanged) |
| `src/fpga/core/mf_pllbase*` | Template PLL (unchanged, see "Video timing") |
| `dist/Cores/namdl0.UFO50/` | `core.json`, `video.json`, `data.json`, `input.json`, ..., `icon.bin`, `info.txt` |
| `dist/Platforms/ufo50.json`, `dist/Platforms/_images/ufo50.bin` | Platform metadata and a placeholder text image |
| `tools/pocket_pack.py` | Bit-reverses `.rbf` to `.rbf_r`, validates `dist/`, builds the SD tree and zip |
| `sim/` | Icarus Verilog testbenches for the video module, plus IP stubs |

`dist/` uses the same layout as the SD card (`Cores/<author>.<core>/`, `Platforms/`),
the convention used by agg23's MIT-licensed cores such as
[openfpga-pong](https://github.com/agg23/openfpga-pong).

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

- **Intel Quartus Prime Lite Edition** with **Cyclone V** device support. The template
  was made with 18.1. Newer Lite releases also work, but they may ask to upgrade
  the PLL IP. If they do, accept the upgrade and keep the same settings.
- **Python 3.8+** from python.org. Tick "Add to PATH". No extra packages are needed.
- (Optional) Icarus Verilog for Windows if you want to re-run the simulations.

### 2. Get the branch

```
git clone https://github.com/namdl0/core-template.git
cd core-template
git checkout ufo50-m1
```

### 3. Compile in Quartus

1. Start Quartus. Choose **File > Open Project** and select `src\fpga\ap_core.qpf`.
2. If a dialog offers to upgrade IP or the project's version, accept it.
3. Choose **Processing > Start Compilation** (Ctrl+L). The first build takes a few minutes.
4. When it finishes, check:
   - The Messages pane has **0 errors**. Expect warnings: the template produces many.
   - In the Compilation Report, under **Timing Analyzer**, nothing is red.
     The video logic runs at 12.288 MHz, so timing should pass easily.
   - `src\fpga\output_files\ap_core.rbf` has a new timestamp. Expect a size near
     0.8 MB, the same as the template.

SignalTap is turned **off** in this branch (`ENABLE_SIGNALTAP OFF` in `ap_core.qsf`).
The template's `stp1.stp` probes `x_count`/`y_count` in `core_top`. Those signals moved
into `ufo50_video`, and the probes are of no use without a JTAG cable anyway.

### 4. Package

From the repo root:

```
py tools\pocket_pack.py package
```

This command:
- validates the JSON files against Analogue's limits (string lengths, slot ids and so on),
- refuses to package if `ap_core.rbf` is still the template's original bitstream,
  which means the compile didn't run,
- bit-reverses `ap_core.rbf` into `Cores\namdl0.UFO50\bitstream.rbf_r`,
- writes the SD tree to `build\sd\` and a zip,
  `build\namdl0.UFO50_0.0.1_2026-10-24.zip`.

To copy the tree straight onto the SD card, add `--sd`, for example
`py tools\pocket_pack.py package --sd E:\`.

To bit-reverse a file by hand: `py tools\pocket_pack.py reverse in.rbf out.rbf_r`.

### 5. Copy to the SD card

If you didn't use `--sd`, extract the zip onto the **root** of the Pocket's SD card. You should end up with:

```
E:\Cores\namdl0.UFO50\bitstream.rbf_r
E:\Cores\namdl0.UFO50\core.json  (and the other .json files, icon.bin, info.txt)
E:\Platforms\ufo50.json
E:\Platforms\_images\ufo50.bin
```

Eject the card safely and put it back in the Pocket.

### 6. What you should see on the Pocket

**openFPGA > UFO 50 > UFO50.** The core starts straight away, with no file browser,
because every data slot is optional for M1. On screen:

- 8 colour bars (white, yellow, cyan, green, magenta, red, blue, black) across the
  top two thirds, a grey ramp under them, then a fine 1x1 checkerboard (left) and a
  2x2 checkerboard (right) at the bottom.
- A **1-pixel white border on the very edge** of the picture with a **red ring** just
  inside it. If the white is visible on all four sides, the 384x216 window is
  exactly aligned and nothing is cropped.
- An orange 24x24 box bouncing around.
- Buttons: hold **A** to turn the box cyan, **B** to freeze it, **Select** for
  greyscale, **Start** to invert the colours.
- The picture fills the width of the screen at 16:9, with bars above and below.
  It's normal for the 1x1 checkerboard to shimmer or show moiré, because 384 to the
  panel width is not an integer scale.
- **Dock:** the same pattern at 16:9 on the TV.

### Troubleshooting

| Symptom | Likely cause |
|---|---|
| Core missing from the list | Folder isn't `Cores\namdl0.UFO50`, or `core.json` is invalid. Run `py tools\pocket_pack.py validate` |
| Pocket says it can't load the bitstream | `bitstream.rbf_r` isn't bit-reversed or is from a failed build. Repackage |
| Black screen, core seems to hang | `reset_n` never released. Check that `core_bridge_cmd.v` is in the project and the compile had no errors |
| Picture shifted or edge cut off | Report which border colour is missing on which side |

## Simulation (optional)

```
sh sim/run_sim.sh            # needs iverilog/vvp on PATH
```

The script runs three checks:
- `tb_ufo50_video.v` runs 6 frames and checks the VS period (204,800 clocks), 400 HS per
  frame, 216 DE lines of exactly 384 pixels, no HS or VS during DE, RGB = 0 outside
  DE, `skip` = 0, the border and ring pixels, and the A and B button effects. It
  writes `sim/frame1.ppm` and `sim/frame3.ppm`, which open in GIMP or IrfanView.
- `tb_box_bounce.v` runs 2,000 frames and checks that the box stays inside 384x216
  and bounces off all four edges.
- An elaboration of `core_top` + `core_bridge_cmd` + `ufo50_video` against stub IP.

## Data slots (`data.json`)

These follow the plan in CORE_PREP.md. For M1 every slot is `required: false`, so
the core boots with no files. The addresses are provisional and will be fixed when
the SDRAM loader exists (M3).

| id | name | file | mode |
|---|---|---|---|
| 0 | Program | `ufo50.gmp` | loaded to 0x00000000 (SDRAM), max 40 MB |
| 1 | Asset Index | `ufo50.gma` | loaded to 0x02800000, max 8 MB |
| 2 | Texture Pack | `ufo50_tex.bin` | `deferload` (core reads it with target command 0x0180) |
| 3 | Audio Pack | `ufo50_snd.bin` | `deferload` |
| 4 | Text | `english.txt` | loaded to 0x03000000, max 1 MB |
| 10-12 | Save 1-3 | `save1.ufo` .. `save3.ufo` | nonvolatile, 64 KB each, 0x20000000+ |
| 13 | Account | `account.ufo` | nonvolatile |
| 14 | Config | `config.json` | nonvolatile, 4 KB |

Asset files go in `/Assets/ufo50/common/` and saves in `/Saves/ufo50/common/`, the
platform-shared locations (parameters bit 1 is clear). The M1 core ignores bridge
writes and returns 0 on reads outside `0xF8xxxxxx`.
