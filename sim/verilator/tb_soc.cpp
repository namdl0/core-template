// tb_soc.cpp - Verilator testbench for the UFO50 M3 SoC (vl_top.v)
//
// Runs the -DSIM build of firmware/hello from boot RAM with:
//   - a cycle-based x16 SDR SDRAM model (CL/BL from the mode register, auto precharge,
//     refresh, DQM) with tRCD/tRP/tRC/tRAS/tRFC/tWR/tREFI checks. dram_clk = ~clk_sys:
//     the SDRAM samples on clk_sys falling edges; read data for edge n is presented to
//     the FPGA's negedge capture at edge n+1 (the middle of the real CL=2 window).
//   - APF emulation: slot 0 (256 bytes) written over the bridge while reset_n is low,
//     data-slot size table (2-clock latency like mf_datatable, writable by the core),
//     target commands 0x0180 (read), 0x0184 (write: the APF reads the core's SDRAM over
//     the bridge, one word per +rdgap= clk_74a cycles, sampling bridge_rd_data at the next
//     strobe) and 0x0188 (flush: the write-back of the slot using the size-table entry, as
//     on quit/sleep/power-off). What the APF read is compared with the SDRAM model.
//   - video capture: sim/out/vl_frame_NN.ppm; frames of the live loop are compared
//     pixel by pixel with the framebuffer contents in the SDRAM model.
//
// Usage: sim/verilator/run.sh   (prints TB_SOC PASS / FAIL)
#include "Vvl_top.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <string>
#include <vector>

static const double T_SYS = 17316.0;   // ps, 57.75 MHz
static const double T_MEM = T_SYS / 2; // ps, 115.5 MHz SDRAM clock (M5, sdram_ctrl2x)
#ifdef SDRAM_1X
static const double T_SD = T_SYS;       // SDRAM on clk_sys (sdram_ctrl, build with -DSDRAM_1X)
#else
static const double T_SD = T_MEM;       // SDRAM on clk_mem
#endif
static const double T_VID = 81380.0;   // 12.288 MHz
static const double T_74A = 13468.0;   // 74.25 MHz

// ------------------------------------------------------------------ SDRAM model
struct Sdram {
    std::vector<uint16_t> mem = std::vector<uint16_t>(1u << 25, 0xDEAD);
    int cl = 2, bl = 1;
    bool mode = false;
    bool open[4] = {};
    int row[4] = {};
    double t_act[4], t_pre[4], t_wr[4], ap_at[4];
    double t_ref = -1e18;
    struct Slot { bool v; uint16_t d; } pipe[16] = {};
    long edge = 0;
    int wr_left = 0, wr_bank = 0;
    uint32_t wr_addr = 0;
    long errors = 0, reads = 0, writes = 0, refs = 0;
    Sdram() { for (int i = 0; i < 4; i++) { t_act[i] = t_pre[i] = t_wr[i] = -1e18; ap_at[i] = -1; } }

    void err(double now, const char *m) {
        if (++errors <= 20) printf("[%.3f us] SDRAM MODEL ERROR: %s\n", now / 1e6, m);
    }
    uint32_t dbg_lo = getenv("DBG_HA_LO") ? strtoul(getenv("DBG_HA_LO"), 0, 16) : 0;
    uint32_t dbg_hi = getenv("DBG_HA_HI") ? strtoul(getenv("DBG_HA_HI"), 0, 16) : 0;
    static uint32_t ha(int b, int r, int c) { return ((uint32_t)r << 12) | ((uint32_t)b << 10) | (uint32_t)c; }

    // data the FPGA sees at the falling clk_sys edge that is SDRAM edge `edge+1`
    uint16_t dq_for_capture(bool &valid) const {
        const Slot &s = pipe[(edge) & 15];
        valid = s.v;
        return s.v ? s.d : 0xBAD0;
    }

    // one SDRAM rising edge (clk_sys falling edge); pins are the FPGA outputs
    void clock(double now, int ras, int cas, int we, int ba, int a, int dqm, uint16_t dq, int cke) {
        pipe[edge & 15].v = false;          // slot of the previous edge has been consumed
        edge++;
        for (int b = 0; b < 4; b++)
            if (ap_at[b] >= 0 && now >= ap_at[b] - 1) { open[b] = false; t_pre[b] = ap_at[b]; ap_at[b] = -1; }
        if (!cke) return;
        int cmd = (ras << 2) | (cas << 1) | we;
        if (wr_left > 0 && cmd != 4) {      // write burst continuation
            uint16_t &m = mem[wr_addr];
            if (!(dqm & 1)) m = (m & 0xFF00) | (dq & 0xFF);
            if (!(dqm & 2)) m = (m & 0x00FF) | (dq & 0xFF00);
            if (wr_addr >= dbg_lo && wr_addr < dbg_hi) printf("SDW %.3f ha %07x = %04x dqm %d\n", now / 1e3, wr_addr, m, dqm);
            wr_addr = (wr_addr & ~7u) | ((wr_addr + 1) & 7u);
            if (--wr_left == 0) t_wr[wr_bank] = now;
        }
        switch (cmd) {
        case 7: break;                                      // NOP
        case 0:                                             // MRS
            for (int b = 0; b < 4; b++) if (open[b]) err(now, "MRS with open bank");
            cl = (a >> 4) & 7;
            bl = 1 << (a & 7);
            if (cl != 2 && cl != 3) err(now, "bad CL");
            if ((a & 7) > 3) err(now, "bad BL");
            mode = true;
            printf("[%.3f us] SDRAM MRS: CL=%d BL=%d\n", now / 1e6, cl, bl);
            break;
        case 1:                                             // REFRESH
            for (int b = 0; b < 4; b++) {
                if (open[b]) err(now, "REFRESH with open bank");
                if (now - t_pre[b] < 15000 - 1) err(now, "tRP before REFRESH");
            }
            if (now - t_ref < 60000 - 1) err(now, "tRFC");
            if (mode && t_ref > 0 && now - t_ref > 7812500) err(now, "refresh interval > tREFI");
            t_ref = now;
            for (int b = 0; b < 4; b++) t_act[b] = now;
            refs++;
            break;
        case 2:                                             // PRECHARGE
            for (int b = 0; b < 4; b++)
                if ((a & 0x400) || ba == b) {
                    if (open[b] && now - t_act[b] < 42000 - 1) err(now, "tRAS");
                    if (open[b] && now - t_wr[b] < 14000 - 1) err(now, "tWR");
                    open[b] = false; t_pre[b] = now;
                }
            break;
        case 3:                                             // ACTIVE
            if (!mode) err(now, "ACTIVE before MRS");
            if (open[ba]) err(now, "ACTIVE to an open bank");
            if (now - t_pre[ba] < 15000 - 1) err(now, "tRP");
            if (now - t_act[ba] < 60000 - 1) err(now, "tRC");
            if (now - t_ref < 60000 - 1) err(now, "tRFC (ACT)");
            open[ba] = true; row[ba] = a; t_act[ba] = now;
            break;
        case 5: {                                           // READ
            if (!open[ba]) err(now, "READ to a closed bank");
            if (now - t_act[ba] < 15000 - 1) err(now, "tRCD (READ)");
            int col = a & 0x3FF;
            for (int j = 0; j < bl; j++) {
                Slot &s = pipe[(edge + cl - 1 + j) & 15];
                s.v = true;
                s.d = mem[ha(ba, row[ba], (col & ~7) | ((col + j) & 7))];
            }
            reads++;
            if (a & 0x400) { ap_at[ba] = now + bl * T_SD; if (ap_at[ba] - t_act[ba] < 42000) ap_at[ba] = t_act[ba] + 42000; }
            break; }
        case 4: {                                           // WRITE
            if (!open[ba]) err(now, "WRITE to a closed bank");
            if (now - t_act[ba] < 15000 - 1) err(now, "tRCD (WRITE)");
            int col = a & 0x3FF;
            wr_addr = ha(ba, row[ba], col);
            uint16_t &m = mem[wr_addr];
            if (!(dqm & 1)) m = (m & 0xFF00) | (dq & 0xFF);
            if (!(dqm & 2)) m = (m & 0x00FF) | (dq & 0xFF00);
            if (wr_addr >= dbg_lo && wr_addr < dbg_hi) printf("SDW %.3f ha %07x = %04x dqm %d (WRITE)\n", now / 1e3, wr_addr, m, dqm);
            wr_addr = (wr_addr & ~7u) | ((wr_addr + 1) & 7u);
            wr_left = bl - 1; wr_bank = ba;
            if (bl == 1) t_wr[ba] = now;
            writes++;
            if (a & 0x400) { ap_at[ba] = now + (bl - 1) * T_SD + 14000; if (ap_at[ba] - t_act[ba] < 42000) ap_at[ba] = t_act[ba] + 42000; }
            break; }
        default: err(now, "unsupported command");
        }
    }
    // byte address (SDRAM offset) -> 16-bit word
    uint16_t hw(uint32_t byte_off) const {
        uint32_t h = byte_off >> 1;                         // halfword address [24:0]
        // controller mapping: col = [10:1], bank = [12:11], row = [25:13] of the byte address
        int col = h & 0x3FF, bank = (h >> 10) & 3, r = (h >> 12) & 0x1FFF;
        return mem[ha(bank, r, col)];
    }
    void set_hw(uint32_t byte_off, uint16_t v) {
        uint32_t h = byte_off >> 1;
        int col = h & 0x3FF, bank = (h >> 10) & 3, r = (h >> 12) & 0x1FFF;
        mem[ha(bank, r, col)] = v;
    }
};

// ------------------------------------------------------------------ main
int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    double max_ms = 300;
    int rd_gap = 150;      // clk_74a cycles between APF bridge read strobes (~2 us; the real APF is slower)
    for (int i = 1; i < argc; i++) if (!strncmp(argv[i], "+max_ms=", 8)) max_ms = atof(argv[i] + 8);
    for (int i = 1; i < argc; i++) if (!strncmp(argv[i], "+rdgap=", 7)) rd_gap = atoi(argv[i] + 7);

    Vvl_top *top = new Vvl_top;
    Sdram sd;
    // +preload=<file>@<hex SDRAM byte offset>: raw little-endian bytes copied into the SDRAM model
    // before reset (benchmarks: firmware/bench). May be given several times.
    bool bench = false; long bench_bad = -1;
    // +boot6=<file>: slot-6 boot test. The file (a tiny "U5RT" image, sim/verilator/boot6_stub.s)
    // is preloaded at the slot-6 address, the APF size table reports it as slot 6, and L3 is held
    // so the -DSIM hello firmware runs the loader. Pass criteria = bench mode (BENCH 01 == 0).
    bool boot6 = false; uint32_t boot6_size = 0;
    for (int i = 1; i < argc; i++) if (!strncmp(argv[i], "+boot6=", 7)) {
        FILE *pf = fopen(argv[i] + 7, "rb");
        if (!pf) { printf("cannot open %s\n", argv[i] + 7); return 1; }
        std::vector<uint8_t> buf; uint8_t tmp[65536]; size_t n;
        while ((n = fread(tmp, 1, sizeof tmp, pf)) > 0) buf.insert(buf.end(), tmp, tmp + n);
        fclose(pf);
        if (buf.size() & 1) buf.push_back(0);
        for (size_t k = 0; k < buf.size(); k += 2) sd.set_hw(0x02880000u + (uint32_t)k, (uint16_t)(buf[k] | buf[k + 1] << 8));
        boot6 = true; boot6_size = (uint32_t)buf.size(); bench = true;
        printf("boot6: %u bytes at the slot-6 address\n", boot6_size);
    }
    for (int i = 1; i < argc; i++) if (!strncmp(argv[i], "+preload=", 9)) {
        std::string a = argv[i] + 9; size_t at = a.rfind('@');
        uint32_t off = (uint32_t)strtoul(a.c_str() + at + 1, NULL, 16);
        FILE *pf = fopen(a.substr(0, at).c_str(), "rb");
        if (!pf) { printf("cannot open %s\n", a.substr(0, at).c_str()); return 1; }
        std::vector<uint8_t> buf; uint8_t tmp[65536]; size_t n;
        while ((n = fread(tmp, 1, sizeof tmp, pf)) > 0) buf.insert(buf.end(), tmp, tmp + n);
        fclose(pf);
        if (buf.size() & 1) buf.push_back(0);
        for (size_t k = 0; k < buf.size(); k += 2) sd.set_hw(off + (uint32_t)k, (uint16_t)(buf[k] | buf[k + 1] << 8));
        printf("preloaded %zu bytes at SDRAM +%08x\n", buf.size(), off);
        bench = true;
    }
    std::vector<uint8_t> slot0(256);
    for (int k = 0; k < 256; k++) slot0[k] = (uint8_t)((k * 37 + 11) ^ (k >> 3));
    auto slot_word = [&](uint32_t o) -> uint32_t {   // big-endian bridge word
        if (o + 3 >= slot0.size()) return 0xFFFFFFFFu;
        return (uint32_t)slot0[o] << 24 | (uint32_t)slot0[o + 1] << 16 | (uint32_t)slot0[o + 2] << 8 | slot0[o + 3];
    };

    // APF state
    struct BW { uint32_t a, d; };
    std::deque<BW> bq;
    int b_gap = 0;
    bool loaded = false, released = false;
    int t_state = 0, t_wait = 0;
    bool t_read_prev = false, t_write_prev = false, t_flush_prev = false;
    uint32_t dt_q1 = 0, dt_addr_r = 0;
    uint32_t dt[64] = {};                 // the data-slot size table BRAM (word 2n id, 2n+1 size)
    int n0180 = 0, n0184 = 0, n0188 = 0;
    // bridge read job (0x0184 / flush): words read from the core's SDRAM over the bridge
    struct RdJob { bool active = false; uint32_t addr = 0, len = 0, k = 0, id = 0; int wait = 0; bool strobed = false; int kind = 0; } rj;
    long save_words = 0, save_bad = 0;
    bool save_test_ran = false, save_test_fail = false;
    // the slot address of save 1 (data.json) for the flush model
    const uint32_t SAVE1_ADDR = 0x13E40000u;
    auto sd_be_word = [&](uint32_t bridge_addr) -> uint32_t {   // big-endian word as the APF expects it
        uint32_t off = bridge_addr & 0x3FFFFFF;
        uint16_t lo = sd.hw(off), hi = sd.hw(off + 2);
        return (uint32_t)(lo & 255) << 24 | (uint32_t)(lo >> 8) << 16 | (uint32_t)(hi & 255) << 8 | (hi >> 8);
    };

    // video
    std::vector<uint32_t> cap(384 * 216);
    int captured = 0, frame_no = 0, cmp_frames = 0;
    long mismatches = 0;
    bool frame_valid = false, cmp_this = false;
    uint32_t fb_at_start = 0;
    bool fmt32_at_start = false;

    uint32_t marker = 0, live = 0;
    bool done = false, trapped = false;

    top->clk_sys = 0; top->clk_vid = 0; top->clk_74a = 0;
    top->rst_mem = 1; top->reset_n = 0;
    top->cont1_key = 0x11;                 // UP + A held
    if (boot6) top->cont1_key |= 1u << 12; // L3: the -DSIM hello firmware then runs the slot-6 loader
    top->eval();

    // clk_mem starts high so that its rising edges coincide with clk_sys rising edges (PLL)
    double t = 0, n_sys = T_SYS / 2, n_mem = T_MEM / 2, n_vid = T_VID / 2, n_74 = T_74A / 2;
    top->clk_mem = 1;
    double next_report = 10e9;
    long sys_cycles = 0;
    long d_start = 0, d_lat = 0, d_n = 0, i_start = 0, i_lat = 0, i_n = 0;
    int i_beats = 0;
    bool d_open = false, i_open = false;

    while (!done && t < max_ms * 1e9) {
        t = std::min(std::min(n_sys, n_mem), std::min(n_vid, n_74));
        if (t >= 1e6) top->rst_mem = 0;

        bool e_sys = (t == n_sys), e_mem = (t == n_mem);
        if (e_sys || e_mem) {
            // apply simultaneous clk_sys / clk_mem edges together, as in hardware
            bool sys_fall = e_sys && top->clk_sys, sys_rise = e_sys && !top->clk_sys;
            bool mem_fall = e_mem && top->clk_mem;
#ifdef SDRAM_1X
            bool sd_edge = sys_fall;      // SDRAM rising edge = controller clock falling edge
#else
            bool sd_edge = mem_fall;
#endif
            if (e_sys) n_sys += T_SYS / 2;
            if (e_mem) n_mem += T_MEM / 2;
            if (sd_edge) { bool v; top->sd_dq_in = sd.dq_for_capture(v); }
            if (e_sys) top->clk_sys = !top->clk_sys;
            if (e_mem) top->clk_mem = !top->clk_mem;
            top->eval();
            if (sd_edge)
                sd.clock(t, top->sd_ras_n, top->sd_cas_n, top->sd_we_n, top->sd_ba, top->sd_a,
                         top->sd_dqm, top->sd_dq_oe ? top->sd_dq_out : 0xFFFF, top->sd_cke);
            (void)sys_fall;
            if (sys_rise) {
                sys_cycles++;
                // D$ line refill latency (command accepted -> last beat), I$ refill (cmd -> 8th beat)
                if (top->dbg_dline) { d_start = sys_cycles; d_open = true; }
                if (d_open && top->dbg_drsp_last) { d_lat += sys_cycles - d_start; d_n++; d_open = false; }
                if (top->dbg_iline) { i_start = sys_cycles; i_beats = 0; i_open = true; }
                if (i_open && top->dbg_irsp && ++i_beats == 8) { i_lat += sys_cycles - i_start; i_n++; i_open = false; }
                if (top->dbg_wr) {
                    marker = top->dbg_val;
                    if ((marker >> 16) == 0xDEAD) {
                        printf("[%.3f ms] FIRMWARE TRAP mcause=%04x\n", t / 1e9, marker & 0xFFFF);
                        trapped = true; done = true;
                    } else if ((marker >> 16) == 1) live = marker & 0xFFFF;
                    else if ((marker >> 16) == 9) {   /* save test (0x0184/0x0188) result from the firmware */
                        save_test_ran = true; save_test_fail = (marker & 1) != 0;
                        printf("[%.3f ms] firmware save test: %s\n", t / 1e9, save_test_fail ? "FAIL" : "ok");
                    }
                    else if ((marker >> 24) == 0xBE) {   /* benchmark firmware: 0xBE tt vvvv (tag, value in units given by tag) */
                        uint32_t tg = (marker >> 16) & 0xFF, v = marker & 0xFFFF;
                        printf("[%.3f ms] BENCH %02x %u\n", t / 1e9, tg, v);
                        if (tg == 0x01) bench_bad = v;
                        if (tg == 0xFF) done = true;
                    }
                    else printf("[%.3f ms] firmware step %u\n", t / 1e9, marker);
                }
            }
        }
        if (t == n_vid) {
            n_vid += T_VID / 2;
            top->clk_vid = !top->clk_vid;
            top->eval();
            if (top->clk_vid) {
                if (top->v_vs) {
                    if (frame_valid && captured == 384 * 216) {
                        char fn[64];
                        snprintf(fn, sizeof fn, "sim/out/vl_frame_%02d.ppm", frame_no);
                        FILE *f = fopen(fn, "wb");
                        if (f) {
                            fprintf(f, "P6\n384 216\n255\n");
                            for (uint32_t p : cap) { fputc(p >> 16, f); fputc((p >> 8) & 255, f); fputc(p & 255, f); }
                            fclose(f);
                        }
                        if (!cmp_this)
                            printf("[%.3f ms] frame %d captured (%s)\n", t / 1e9, frame_no, fn);
                        frame_no++;
                        if (live >= 3 && cmp_frames >= 2) done = true;
                    }
                    frame_valid = (top->v_mode == 1);
                    captured = 0;
                }
                if (top->v_de && captured < 384 * 216) {
                    if (captured == 0) { fb_at_start = top->fb_active; fmt32_at_start = top->fb_fmt32; cmp_this = (marker == 7) || live > 0; }
                    cap[captured++] = top->v_rgb;
                    // compare at the last active pixel: in vertical blank the firmware may already
                    // draw into this buffer again (it is the next back buffer)
                    if (captured == 384 * 216 && cmp_this) {
                        cmp_frames++;
                        uint32_t base = fb_at_start & 0x3FFFFFF;
                        long before = mismatches;
                        for (int a = 0; a < 384 * 216; a++) {
                            uint32_t e;
                            if (fmt32_at_start) {   // ABGR8888 (0xAABBGGRR), shown as RGB888
                                uint32_t lo = sd.hw(base + 4 * a), hi = sd.hw(base + 4 * a + 2);
                                e = ((lo & 255) << 16) | (lo & 0xFF00) | (hi & 255);
                            } else {
                                uint16_t px = sd.hw(base + 2 * a);
                                uint32_t r = (px >> 11) & 31, g = (px >> 5) & 63, b = px & 31;
                                e = ((r << 3 | r >> 2) << 16) | ((g << 2 | g >> 4) << 8) | (b << 3 | b >> 2);
                            }
                            if (e != cap[a]) {
                                if (mismatches < 10)
                                    printf("pixel mismatch frame %d (%d,%d): got %06x want %06x\n",
                                           frame_no, a % 384, a / 384, cap[a], e);
                                mismatches++;
                            }
                        }
                        printf("[%.3f ms] frame %d (buffer %08x, %s) compared with SDRAM: %ld mismatches\n",
                               t / 1e9, frame_no, fb_at_start, fmt32_at_start ? "ABGR8888" : "RGB565", mismatches - before);
                    }
                }
            }
        }
        if (t == n_74) {
            n_74 += T_74A / 2;
            top->clk_74a = !top->clk_74a;
            top->eval();
            if (top->clk_74a) {
                // datatable: registered address + registered output
                // edge E0: address changes; E1: address register; E2: output register -> q seen at E3
                top->dt_q = dt_q1;
                dt[1] = (uint32_t)slot0.size();
                if (boot6) { dt[2] = 6u; dt[3] = boot6_size; }
                dt_q1 = dt[dt_addr_r & 63];
                if (top->dt_wren) { dt[top->dt_addr & 63] = top->dt_data;
                    printf("[%.3f ms] APF: size table[%u] <= %u\n", t / 1e9, top->dt_addr, top->dt_data); }
                if (getenv("DT_DEBUG") && top->dt_addr != dt_addr_r) printf("[%.3f ms] dt_addr %u\n", t / 1e9, top->dt_addr);
                dt_addr_r = top->dt_addr;
                // bridge reads (0x0184 / flush): strobe word k, sample bridge_rd_data at the next strobe
                top->bridge_rd = 0;
                if (rj.active) {
                    if (rj.wait > 0) rj.wait--;
                    else {
                        if (rj.strobed) {   // the previous strobe's data is on bridge_rd_data now
                            uint32_t got = top->bridge_rd_data, want = sd_be_word(rj.addr + 4 * (rj.k - 1));
                            save_words++;
                            if (got != want) { if (save_bad < 10) printf("[%.3f ms] APF: bridge read %08x: got %08x want %08x\n", t / 1e9, rj.addr + 4 * (rj.k - 1), got, want); save_bad++; }
                        }
                        if (rj.k * 4 < rj.len) {
                            top->bridge_addr = rj.addr + 4 * rj.k; top->bridge_rd = 1; rj.strobed = true; rj.k++; rj.wait = rd_gap;
                        } else rj.active = false;
                    }
                }
                // bridge writes
                top->bridge_wr = 0;
                if (b_gap > 0) b_gap--;
                else if (!bq.empty()) {
                    top->bridge_addr = bq.front().a; top->bridge_wr_data = bq.front().d; top->bridge_wr = 1;
                    bq.pop_front();
                    b_gap = 6;
                }
                // boot: load slot 0 while reset_n is low, then release
                if (!loaded && t > 21e6) {
                    printf("[%.3f ms] APF: loading slot 0 (%zu bytes) over the bridge\n", t / 1e9, slot0.size());
                    // benchmarks preload SDRAM from +0 themselves: the slot-0 test file would overwrite it
                    if (!bench) for (uint32_t k = 0; k < slot0.size(); k += 4) bq.push_back({0x10000000u + k, slot_word(k)});
                    loaded = true;
                }
                if (loaded && !released && bq.empty() && b_gap == 0) {
                    top->reset_n = 1; released = true;
                    printf("[%.3f ms] APF: reset_n released\n", t / 1e9);
                }
                // target commands 0x0180 (read), 0x0184 (write), 0x0188 (flush)
                bool tr = top->t_read, tw = top->t_write, tf = top->t_flush;
                static int t_cmd = 0;
                if (tr && !t_read_prev && t_state == 0) { t_state = 1; t_wait = 4; n0180++; t_cmd = 0x180; }
                if (tw && !t_write_prev && t_state == 0) { t_state = 1; t_wait = 4; n0184++; t_cmd = 0x184; }
                if (tf && !t_flush_prev && t_state == 0) { t_state = 1; t_wait = 4; n0188++; t_cmd = 0x188; }
                t_read_prev = tr; t_write_prev = tw; t_flush_prev = tf;
                switch (t_state) {
                case 1: if (--t_wait == 0) { top->t_done = 0; t_state = 2; t_wait = 30; } break;
                case 2:
                    if (--t_wait == 0) {
                        top->t_ack = 1;
                        if (t_cmd == 0x180) {
                            for (uint32_t k = 0; k < top->t_len; k += 4)
                                bq.push_back({top->t_baddr + k, top->t_id == 0 ? slot_word(top->t_off + k) : 0xFFFFFFFFu});
                        } else if (t_cmd == 0x184) {
                            rj = RdJob(); rj.active = true; rj.addr = top->t_baddr; rj.len = top->t_len; rj.id = top->t_id; rj.wait = 20;
                        } else {   // flush: write the slot back from its address, size from the table (as on quit)
                            uint32_t sz = 0;
                            for (int e = 0; e < 32; e++) if ((dt[2 * e] & 0xFFFF) == top->t_id && dt[2 * e + 1]) sz = dt[2 * e + 1];
                            rj = RdJob(); rj.active = sz != 0; rj.addr = SAVE1_ADDR; rj.len = sz; rj.id = top->t_id; rj.wait = 20;
                            printf("[%.3f ms] APF: 0x0188 slot %u: table size %u\n", t / 1e9, top->t_id, sz);
                        }
                        t_state = 3;
                    }
                    break;
                case 3:
                    if (bq.empty() && b_gap == 0 && !rj.active) {
                        bool ok = t_cmd == 0x180 ? top->t_id == 0 : (top->t_id == 10 && save_bad == 0);
                        top->t_ack = 0; top->t_err = ok ? 0 : 2; top->t_done = 1; t_state = 0;
                        printf("[%.3f ms] APF: 0x%04x slot %u off %u -> %08x len %u done%s\n",
                               t / 1e9, t_cmd, top->t_id, top->t_off, top->t_baddr, top->t_len, ok ? "" : " (error)");
                    }
                    break;
                }
                top->eval();
            }
        }
        if (t >= next_report) {
            printf("[%.3f ms] ... marker %08x, live frames %u, %ld sys cycles\n", t / 1e9, marker, live, sys_cycles);
            fflush(stdout);
            next_report += 10e9;
        }
    }

    printf("---------------------------------------------------------------\n");
    printf("SDRAM model: %ld errors, %ld reads, %ld writes, %ld refreshes\n", sd.errors, sd.reads, sd.writes, sd.refs);
    printf("frames compared %d, pixel mismatches %ld, live frames %u, 0x0180 commands %d, sim time %.2f ms\n",
           cmp_frames, mismatches, live, n0180, t / 1e9);
    printf("save write-back: %d x 0x0184, %d x 0x0188, %ld words read over the bridge, %ld wrong, firmware test %s\n",
           n0184, n0188, save_words, save_bad, save_test_ran ? (save_test_fail ? "FAIL" : "PASS") : "not run");
    printf("D$ line refills %ld, avg %.1f cycles; I$ line refills %ld, avg %.1f cycles (incl. boot RAM)\n",
           d_n, d_n ? (double)d_lat / d_n : 0.0, i_n, i_n ? (double)i_lat / i_n : 0.0);
    bool save_ok = save_bad == 0 && !save_test_fail && (bench || (save_test_ran && n0184 >= 2 && n0188 >= 1 && save_words > 0));
    bool pass = bench ? (!trapped && sd.errors == 0 && bench_bad == 0 && save_ok)
                      : (!trapped && sd.errors == 0 && mismatches == 0 && cmp_frames >= 2 && live >= 3 && n0180 >= 1 && save_ok);
    printf(pass ? "TB_SOC PASS\n" : "TB_SOC FAIL\n");
    top->final();
    delete top;
    return pass ? 0 : 1;
}
