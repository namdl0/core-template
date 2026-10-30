//
// ufo50_soc.v - UFO50 Pocket SoC (milestone M3)
//
// VexRiscv RV32IMFD (cpu/VexRiscv.v) + 32 KB boot RAM + 64 MB SDRAM + MMIO.
// Address map, registers and peripheral ports: docs/MEMORY_MAP.md (the contract).
//
//   iBus (native I$ refill bus, 32-bit)  -> boot RAM port A | SDRAM port 4
//   dBus (native D$ bus, 64-bit)         -> boot RAM port B | SDRAM port 3 | MMIO
//   MMIO (Wishbone classic, 32-bit)      -> sysregs 0x8000 | dataslot 0x8001 |
//                                           blitter 0x8002 | mixer 0x8003
//   SDRAM arbiter ports: 0 video, 1 bridge (APF), 2 mixer (X1), 3 dBus, 4 iBus, 5 blitter (X0)
//
`default_nettype none

module ufo50_soc #(
    parameter CLK_SYS_HZ  = 32'd57_750_000,
    parameter BOOT_HEX    = "core/fw/boot",     // boot_b0.hex .. boot_b3.hex (byte lanes)
    parameter SDRAM_INIT_CYCLES = 16'd12000,      // clk_sys cycles (doubled for the 2x controller)
    parameter SDRAM_2X    = 1                   // 1: sdram_ctrl2x on clk_mem = 2 x clk_sys; 0: sdram_ctrl
)(
    input  wire         clk_sys,
    input  wire         clk_mem,        // 2 x clk_sys, same PLL (unused if SDRAM_2X = 0)
    input  wire         rst_mem,        // PLL not locked: resets SDRAM ctrl and bridge path
    input  wire         rst_sys,        // also held while the APF holds reset_n low

    // SDRAM pins (registered)
    output wire [12:0]  sd_a,
    output wire [1:0]   sd_ba,
    output wire [1:0]   sd_dqm,
    output wire         sd_cke,
    output wire         sd_ras_n,
    output wire         sd_cas_n,
    output wire         sd_we_n,
    output wire [15:0]  sd_dq_out,
    output wire         sd_dq_oe,
    input  wire [15:0]  sd_dq_in,

    // video (clk_vid domain)
    input  wire         clk_vid,
    input  wire [9:0]   vid_x,
    input  wire [9:0]   vid_y,
    output wire [23:0]  vid_fb_rgb,
    output reg  [1:0]   vid_mode,       // sys domain, quasi-static: 0 border colour, 1 framebuffer, 2 test pattern
    output reg  [23:0]  vid_border,

    // APF side (clk_74a domain)
    input  wire         clk_74a,
    input  wire [31:0]  bridge_addr,
    input  wire         bridge_wr,
    input  wire [31:0]  bridge_wr_data,
    input  wire         bridge_rd,
    output wire [31:0]  bridge_rd_data,         // for bridge_addr in SDRAM (0x1xxx_xxxx), see bridge_sdram.v
    output wire         target_dataslot_read,
    output wire         target_dataslot_write,
    output wire         target_dataslot_flush,
    output wire [15:0]  target_dataslot_id,
    output wire [31:0]  target_dataslot_slotoffset,
    output wire [31:0]  target_dataslot_bridgeaddr,
    output wire [31:0]  target_dataslot_length,
    input  wire         target_dataslot_ack,
    input  wire         target_dataslot_done,
    input  wire [2:0]   target_dataslot_err,
    output wire [9:0]   datatable_addr,
    output wire         datatable_wren,
    output wire [31:0]  datatable_data,
    input  wire [31:0]  datatable_q,
    input  wire         dataslot_allcomplete,
    input  wire         osnotify_inmenu,
    input  wire [31:0]  rtc_epoch_seconds,
    input  wire         rtc_valid,
    input  wire [127:0] cont_key,       // {cont4, cont3, cont2, cont1}
    input  wire [127:0] cont_joy,
    input  wire [63:0]  cont_trig,

    // audio (clk_sys)
    input  wire         audio_tick,
    output reg  [15:0]  audio_l,
    output reg  [15:0]  audio_r
);

// ===========================================================================
// CPU
// ===========================================================================
    // Cache configuration cpu/VexRiscv.v was generated with (cpu/README.md: ICACHE_KB, DCACHE_KB,
    // CACHE_WAYS). Reported in SYS_CONFIG; change together with VexRiscv.v.
    localparam [7:0] ICACHE_KB   = 8'd64;
    localparam [7:0] DCACHE_KB   = 8'd32;
    localparam [3:0] ICACHE_WAYS = 4'd2;
    localparam [3:0] DCACHE_WAYS = 4'd2;
    wire        iBus_cmd_valid;
    wire        iBus_cmd_ready;
    wire [31:0] iBus_cmd_payload_address;
    wire [2:0]  iBus_cmd_payload_size;
    wire        iBus_rsp_valid;
    wire [31:0] iBus_rsp_payload_data;
    wire        iBus_rsp_payload_error;

    wire        dBus_cmd_valid;
    wire        dBus_cmd_ready;
    wire        dBus_cmd_payload_wr;
    wire        dBus_cmd_payload_uncached;
    wire [31:0] dBus_cmd_payload_address;
    wire [63:0] dBus_cmd_payload_data;
    wire [7:0]  dBus_cmd_payload_mask;
    wire [2:0]  dBus_cmd_payload_size;
    wire        dBus_cmd_payload_last;
    wire        dBus_rsp_valid;
    wire        dBus_rsp_payload_last;
    wire [63:0] dBus_rsp_payload_data;
    wire        dBus_rsp_payload_error;

    wire        timer_irq;
    wire        ext_irq;

VexRiscv cpu (
    .clk                        ( clk_sys ),
    .reset                      ( rst_sys ),
    .iBus_cmd_valid             ( iBus_cmd_valid ),
    .iBus_cmd_ready             ( iBus_cmd_ready ),
    .iBus_cmd_payload_address   ( iBus_cmd_payload_address ),
    .iBus_cmd_payload_size      ( iBus_cmd_payload_size ),
    .iBus_rsp_valid             ( iBus_rsp_valid ),
    .iBus_rsp_payload_data      ( iBus_rsp_payload_data ),
    .iBus_rsp_payload_error     ( iBus_rsp_payload_error ),
    .dBus_cmd_valid             ( dBus_cmd_valid ),
    .dBus_cmd_ready             ( dBus_cmd_ready ),
    .dBus_cmd_payload_wr        ( dBus_cmd_payload_wr ),
    .dBus_cmd_payload_uncached  ( dBus_cmd_payload_uncached ),
    .dBus_cmd_payload_address   ( dBus_cmd_payload_address ),
    .dBus_cmd_payload_data      ( dBus_cmd_payload_data ),
    .dBus_cmd_payload_mask      ( dBus_cmd_payload_mask ),
    .dBus_cmd_payload_size      ( dBus_cmd_payload_size ),
    .dBus_cmd_payload_last      ( dBus_cmd_payload_last ),
    .dBus_rsp_valid             ( dBus_rsp_valid ),
    .dBus_rsp_payload_last      ( dBus_rsp_payload_last ),
    .dBus_rsp_payload_data      ( dBus_rsp_payload_data ),
    .dBus_rsp_payload_error     ( dBus_rsp_payload_error ),
    .timerInterrupt             ( timer_irq ),
    .externalInterrupt          ( ext_irq ),
    .softwareInterrupt          ( 1'b0 )
);

// ===========================================================================
// SDRAM controller + arbiter
// ===========================================================================
    localparam NP = 6;
    wire [NP-1:0]    p_valid, p_we, p_ready, p_wready, p_rvalid;
    wire [NP*24-1:0] p_addr;
    wire [NP*6-1:0]  p_len;           // beats - 1 per port (1..64 beats, within one 2 KB SDRAM row)
    wire [NP*32-1:0] p_wdata;
    wire [NP*4-1:0]  p_wstrb;
    wire [31:0]      p_rdata;

    wire        c_valid, c_ready, c_we, c_wready, c_rvalid, c_idle, sd_init_done;
    wire [25:2] c_addr;
    wire [5:0]  c_len;
    wire [31:0] c_wdata, c_rdata;
    wire [3:0]  c_wstrb;
    wire        arb_busy;
    wire        c_stop, c_cut;
    wire [5:0]  c_cut_rem;
    wire [25:2] c_cut_addr;
    wire [2:0]  arb_owner;

`ifdef UFO50_NO_PREEMPT
sdram_arb #( .N(NP), .PREEMPT(0) ) arb (      // simulation only: the arbiter without burst preemption
`else
sdram_arb #( .N(NP) ) arb (
`endif
    .clk(clk_sys), .rst(rst_mem),
    .p_valid(p_valid), .p_we(p_we), .p_addr(p_addr), .p_len(p_len),
    .p_wdata(p_wdata), .p_wstrb(p_wstrb), .p_ready(p_ready), .p_wready(p_wready),
    .p_rvalid(p_rvalid), .p_rdata(p_rdata),
    .c_valid(c_valid), .c_ready(c_ready), .c_we(c_we), .c_addr(c_addr), .c_len(c_len),
    .c_wdata(c_wdata), .c_wstrb(c_wstrb), .c_wready(c_wready), .c_rdata(c_rdata), .c_rvalid(c_rvalid),
    .busy_o(arb_busy), .owner_o(arb_owner),
    .c_stop(c_stop), .c_cut(c_cut), .c_cut_rem(c_cut_rem), .c_cut_addr(c_cut_addr)
);

generate if (SDRAM_2X) begin : g_sd2x
sdram_ctrl2x #( .INIT_CYCLES(SDRAM_INIT_CYCLES * 2) ) sdc (
    .clk(clk_sys), .rst(rst_mem),
    .cmd_valid(c_valid), .cmd_ready(c_ready), .cmd_we(c_we), .cmd_addr(c_addr), .cmd_len(c_len),
    .wdata(c_wdata), .wstrb(c_wstrb), .wready(c_wready), .rdata(c_rdata), .rvalid(c_rvalid),
    .idle(c_idle), .init_done(sd_init_done),
    .clk_mem(clk_mem),
    .sd_a(sd_a), .sd_ba(sd_ba), .sd_dqm(sd_dqm), .sd_cke(sd_cke), .sd_ras_n(sd_ras_n),
    .sd_cas_n(sd_cas_n), .sd_we_n(sd_we_n), .sd_dq_out(sd_dq_out), .sd_dq_oe(sd_dq_oe), .sd_dq_in(sd_dq_in)
);
    assign c_cut = 1'b0; assign c_cut_rem = 6'd0; assign c_cut_addr = 24'd0;   // 2x controller: no burst preemption
end else begin : g_sd1x
sdram_ctrl #( .INIT_CYCLES(SDRAM_INIT_CYCLES) ) sdc (
    .clk(clk_sys), .rst(rst_mem),
    .stop(c_stop), .cut(c_cut), .cut_rem(c_cut_rem), .cut_addr(c_cut_addr),
    .cmd_valid(c_valid), .cmd_ready(c_ready), .cmd_we(c_we), .cmd_addr(c_addr), .cmd_len(c_len),
    .wdata(c_wdata), .wstrb(c_wstrb), .wready(c_wready), .rdata(c_rdata), .rvalid(c_rvalid),
    .idle(c_idle), .init_done(sd_init_done),
    .sd_a(sd_a), .sd_ba(sd_ba), .sd_dqm(sd_dqm), .sd_cke(sd_cke), .sd_ras_n(sd_ras_n),
    .sd_cas_n(sd_cas_n), .sd_we_n(sd_we_n), .sd_dq_out(sd_dq_out), .sd_dq_oe(sd_dq_oe), .sd_dq_in(sd_dq_in)
);
end endgenerate

// ===========================================================================
// Boot RAM: 32 KB, 4 byte lanes of 8192 x 8, port A = iBus (read), port B = dBus
// ===========================================================================
    wire [12:0] bra_addr;
    reg  [31:0] bra_q;
    reg  [12:0] brb_addr;
    reg  [31:0] brb_wdata;
    reg  [3:0]  brb_we;
    reg  [31:0] brb_q;

    reg [7:0] bram0 [0:8191];
    reg [7:0] bram1 [0:8191];
    reg [7:0] bram2 [0:8191];
    reg [7:0] bram3 [0:8191];
    initial begin
        $readmemh({BOOT_HEX, "_b0.hex"}, bram0);
        $readmemh({BOOT_HEX, "_b1.hex"}, bram1);
        $readmemh({BOOT_HEX, "_b2.hex"}, bram2);
        $readmemh({BOOT_HEX, "_b3.hex"}, bram3);
    end
    always @(posedge clk_sys) begin
        bra_q[7:0]   <= bram0[bra_addr];
        bra_q[15:8]  <= bram1[bra_addr];
        bra_q[23:16] <= bram2[bra_addr];
        bra_q[31:24] <= bram3[bra_addr];
    end
    always @(posedge clk_sys) begin
        if (brb_we[0]) bram0[brb_addr] <= brb_wdata[7:0];
        brb_q[7:0] <= bram0[brb_addr];
    end
    always @(posedge clk_sys) begin
        if (brb_we[1]) bram1[brb_addr] <= brb_wdata[15:8];
        brb_q[15:8] <= bram1[brb_addr];
    end
    always @(posedge clk_sys) begin
        if (brb_we[2]) bram2[brb_addr] <= brb_wdata[23:16];
        brb_q[23:16] <= bram2[brb_addr];
    end
    always @(posedge clk_sys) begin
        if (brb_we[3]) bram3[brb_addr] <= brb_wdata[31:24];
        brb_q[31:24] <= bram3[brb_addr];
    end

// ===========================================================================
// iBus fabric
// ===========================================================================
    localparam [1:0] IB_IDLE = 2'd0, IB_BRAM = 2'd1, IB_SD = 2'd2, IB_ERR = 2'd3;
    reg  [1:0]  ib_state;
    reg  [31:2] ib_word;
    reg  [3:0]  ib_left;        // beats to issue - 1
    reg  [3:0]  ib_rleft;       // beats to return - 1
    reg         ib_issued;
    reg         ib_bv;          // boot RAM read returning this cycle

    assign iBus_cmd_ready = (ib_state == IB_IDLE);
    assign bra_addr = ib_word[14:2];

    wire        ib_line = (iBus_cmd_payload_size == 3'd5);
    wire [3:0]  ib_n    = ib_line ? 4'd7 : 4'd0;

    // SDRAM port 4
    assign p_valid[4]          = (ib_state == IB_SD) && !ib_issued;
    assign p_we[4]             = 1'b0;
    assign p_addr[4*24 +: 24]  = ib_word[25:2];
    assign p_len[4*6 +: 6]     = {3'b000, ib_left[2:0]};
    assign p_wdata[4*32 +: 32] = 32'd0;
    assign p_wstrb[4*4 +: 4]   = 4'd0;

    assign iBus_rsp_valid         = ib_bv || p_rvalid[4] || (ib_state == IB_ERR);
    assign iBus_rsp_payload_data  = ib_bv ? bra_q : p_rdata;
    assign iBus_rsp_payload_error = (ib_state == IB_ERR);

always @(posedge clk_sys) begin
    ib_bv <= 1'b0;
    if (rst_sys) begin
        ib_state  <= IB_IDLE;
        ib_issued <= 1'b0;
    end else case (ib_state)
    IB_IDLE: if (iBus_cmd_valid) begin
        ib_word   <= ib_line ? {iBus_cmd_payload_address[31:5], 3'b000} : iBus_cmd_payload_address[31:2];
        ib_left   <= ib_n;
        ib_rleft  <= ib_n;
        ib_issued <= 1'b0;
        case (iBus_cmd_payload_address[31:28])
        4'h0:    ib_state <= IB_BRAM;
        4'h1:    ib_state <= IB_SD;
        default: ib_state <= IB_ERR;
        endcase
    end
    IB_BRAM: begin
        ib_bv   <= 1'b1;
        ib_word <= ib_word + 30'd1;
        if (ib_left == 4'd0) ib_state <= IB_IDLE;   // last beat returns next cycle
        else ib_left <= ib_left - 4'd1;
    end
    IB_SD: begin
        if (p_ready[4]) ib_issued <= 1'b1;
        if (p_rvalid[4]) begin
            if (ib_rleft == 4'd0) ib_state <= IB_IDLE;
            else ib_rleft <= ib_rleft - 4'd1;
        end
    end
    IB_ERR: begin
        if (ib_left == 4'd0) ib_state <= IB_IDLE;
        else ib_left <= ib_left - 4'd1;
    end
    endcase
end

// ===========================================================================
// dBus fabric
// ===========================================================================
    localparam [3:0] DB_IDLE = 4'd0, DB_BR_R = 4'd1, DB_BR_W = 4'd2, DB_SD_R = 4'd3,
                     DB_SD_W = 4'd4, DB_IO = 4'd5, DB_IO_W2 = 4'd6, DB_UNM = 4'd7,
                     DB_BR_W2 = 4'd8, DB_BR_WAIT = 4'd15;
    reg  [3:0]  db_state;
    reg  [31:0] db_addr;
    reg  [63:0] db_data;
    reg  [7:0]  db_mask;
    reg         db_line;
    reg  [3:0]  db_issue;       // words left to issue - 1
    reg  [3:0]  db_ret;         // words left to return - 1
    reg  [31:0] db_lo;          // even word of the beat being assembled
    reg         db_odd;         // next returned word is the odd (high) one
    reg         db_issued;
    reg         db_bv;
    reg         db_wbeat;       // SDRAM write: current beat index

    reg         dBus_wr_q;      // write flag of the latched command
    always @(posedge clk_sys)
        if (db_state == DB_IDLE && dBus_cmd_valid) dBus_wr_q <= dBus_cmd_payload_wr;

    reg         d_rsp_v;
    reg  [63:0] d_rsp_d;
    reg         d_rsp_last;
    assign dBus_rsp_valid         = d_rsp_v;
    assign dBus_rsp_payload_data  = d_rsp_d;
    assign dBus_rsp_payload_last  = d_rsp_last;
    assign dBus_rsp_payload_error = 1'b0;
    assign dBus_cmd_ready         = (db_state == DB_IDLE);

    wire [3:0]  d_reg  = dBus_cmd_payload_address[31:28];
    wire        d_line = (dBus_cmd_payload_size == 3'd5) && !dBus_cmd_payload_wr;

    // SDRAM port 3
    wire        db_wlo = |db_mask[3:0];
    wire        db_whi = |db_mask[7:4];
    assign p_valid[3]          = ((db_state == DB_SD_R) || (db_state == DB_SD_W)) && !db_issued;
    assign p_we[3]             = (db_state == DB_SD_W);
    assign p_addr[3*24 +: 24]  = (db_state == DB_SD_W) ? {db_addr[25:3], (db_wlo ? 1'b0 : 1'b1)}
                                       : db_line ? {db_addr[25:5], 3'b000} : {db_addr[25:3], 1'b0};
    assign p_len[3*6 +: 6]     = (db_state == DB_SD_W) ? {5'b00000, db_wlo & db_whi} : {3'b000, db_issue[2:0]};
    assign p_wdata[3*32 +: 32] = (db_wbeat || !db_wlo) ? db_data[63:32] : db_data[31:0];
    assign p_wstrb[3*4 +: 4]   = (db_wbeat || !db_wlo) ? db_mask[7:4]   : db_mask[3:0];

    // MMIO master (Wishbone classic, 32-bit)
    reg         m_cyc;
    reg         m_we;
    reg  [31:2] m_adr;
    reg  [3:0]  m_sel;
    reg  [31:0] m_dat_w;
    wire [31:0] m_dat_r;
    wire        m_ack;

    // returned 32-bit word stream (boot RAM or SDRAM) -> 64-bit beats
    wire        w_v = db_bv || p_rvalid[3];
    wire [31:0] w_d = db_bv ? brb_q : p_rdata;

always @(posedge clk_sys) begin
    d_rsp_v <= 1'b0;
    db_bv   <= 1'b0;
    brb_we  <= 4'd0;
    if (rst_sys) begin
        db_state  <= DB_IDLE;
        m_cyc     <= 1'b0;
        db_issued <= 1'b0;
    end else begin
        // beat assembly for reads
        if (w_v) begin
            if (!db_odd) db_lo <= w_d;
            else begin
                d_rsp_v    <= 1'b1;
                d_rsp_d    <= {w_d, db_lo};
                d_rsp_last <= (db_ret == 4'd0);
            end
            db_odd <= ~db_odd;
            if (db_ret == 4'd0) db_state <= DB_IDLE;
            else db_ret <= db_ret - 4'd1;
        end

        case (db_state)
        DB_IDLE: if (dBus_cmd_valid) begin
            db_addr   <= dBus_cmd_payload_address;
            db_data   <= dBus_cmd_payload_data;
            db_mask   <= dBus_cmd_payload_mask;
            db_line   <= d_line;
            db_issue  <= d_line ? 4'd7 : 4'd1;
            db_ret    <= d_line ? 4'd7 : 4'd1;
            db_odd    <= 1'b0;
            db_issued <= 1'b0;
            db_wbeat  <= 1'b0;
            brb_addr  <= d_line ? {dBus_cmd_payload_address[14:5], 3'b000}
                                : {dBus_cmd_payload_address[14:3], 1'b0};
            casez (d_reg)
            4'h0: db_state <= dBus_cmd_payload_wr ? DB_BR_W : DB_BR_R;
            4'h1, 4'h5: db_state <= dBus_cmd_payload_wr ? DB_SD_W : DB_SD_R;
            4'b1???: begin
                db_state <= DB_IO;
                m_cyc    <= 1'b1;
                m_we     <= dBus_cmd_payload_wr;
                if (dBus_cmd_payload_wr && (dBus_cmd_payload_mask[3:0] == 4'd0)) begin
                    m_adr   <= {dBus_cmd_payload_address[31:3], 1'b1};
                    m_sel   <= dBus_cmd_payload_mask[7:4];
                    m_dat_w <= dBus_cmd_payload_data[63:32];
                end else if (dBus_cmd_payload_wr) begin
                    m_adr   <= {dBus_cmd_payload_address[31:3], 1'b0};
                    m_sel   <= dBus_cmd_payload_mask[3:0];
                    m_dat_w <= dBus_cmd_payload_data[31:0];
                end else begin
                    m_adr   <= dBus_cmd_payload_address[31:2];
                    m_sel   <= 4'hF;
                end
            end
            default: db_state <= DB_UNM;
            endcase
        end

        DB_BR_R: begin              // issue reads, one word per cycle
            db_bv <= 1'b1;
            if (db_issue == 4'd0) db_state <= DB_BR_WAIT;     // last word returns next cycle (w_v)
            else begin
                db_issue <= db_issue - 4'd1;
                brb_addr <= brb_addr + 13'd1;
            end
        end

        DB_BR_W: begin
            brb_wdata <= db_data[31:0];
            brb_we    <= db_mask[3:0];
            db_state  <= DB_BR_W2;
        end
        DB_BR_W2: begin
            brb_addr  <= brb_addr + 13'd1;
            brb_wdata <= db_data[63:32];
            brb_we    <= db_mask[7:4];
            db_state  <= DB_IDLE;
        end

        DB_SD_R: begin
            if (p_ready[3]) db_issued <= 1'b1;
        end

        DB_SD_W: begin
            if (p_ready[3]) db_issued <= 1'b1;
            if (p_wready[3]) begin
                db_wbeat <= 1'b1;
                if (!(db_wlo && db_whi) || db_wbeat) db_state <= DB_IDLE;
            end
        end

        DB_IO: if (m_ack) begin
            m_cyc <= 1'b0;
            if (!m_we) begin
                d_rsp_v    <= 1'b1;
                d_rsp_d    <= {m_dat_r, m_dat_r};
                d_rsp_last <= 1'b1;
                db_state   <= DB_IDLE;
            end else if (db_mask[3:0] != 4'd0 && db_mask[7:4] != 4'd0 && !m_adr[2]) begin
                db_state <= DB_IO_W2;
            end else
                db_state <= DB_IDLE;
        end
        DB_IO_W2: begin             // second word of a 64-bit MMIO store
            m_cyc   <= 1'b1;
            m_adr   <= {m_adr[31:3], 1'b1};
            m_sel   <= db_mask[7:4];
            m_dat_w <= db_data[63:32];
            db_state <= DB_IO;
        end

        DB_UNM: begin               // unmapped: reads return 0xDEADBEEF, writes dropped
            if (!dBus_wr_q) begin
                d_rsp_v    <= 1'b1;
                d_rsp_d    <= {2{32'hDEAD_BEEF}};
                d_rsp_last <= (db_ret[3:1] == 3'd0);
                if (db_ret[3:1] == 3'd0) db_state <= DB_IDLE;
                else db_ret <= db_ret - 4'd2;
            end else
                db_state <= DB_IDLE;
        end

        DB_BR_WAIT: ;               // boot RAM read: waiting for the last word
        default: ;
        endcase
    end
end

// ===========================================================================
// MMIO decode: 64 KB windows at 0x8000_0000 + n * 0x1_0000
// ===========================================================================
    wire [11:0] m_win = m_adr[27:16];
    wire        m_stb = m_cyc;
    wire        sel_sys  = m_stb && (m_adr[31:28] == 4'h8) && (m_win == 12'd0);
    wire        sel_ds   = m_stb && (m_adr[31:28] == 4'h8) && (m_win == 12'd1);
    wire        sel_blit = m_stb && (m_adr[31:28] == 4'h8) && (m_win == 12'd2);
    wire        sel_mix  = m_stb && (m_adr[31:28] == 4'h8) && (m_win == 12'd3);
    wire        sel_none = m_stb && !(sel_sys || sel_ds || sel_blit || sel_mix);

    wire [31:0] sys_dat, ds_dat, blit_dat, mix_dat;
    wire        sys_ack, ds_ack, blit_ack, mix_ack;
    reg         none_ack;
    always @(posedge clk_sys) none_ack <= sel_none && !none_ack;

    assign m_ack   = sys_ack | ds_ack | blit_ack | mix_ack | none_ack;
    assign m_dat_r = sel_sys ? sys_dat : sel_ds ? ds_dat : sel_blit ? blit_dat : sel_mix ? mix_dat : 32'd0;

// ===========================================================================
// System registers (0x8000_0000)
// ===========================================================================
    // input synchronisers (APF signals are quasi-static, clk_74a domain)
    reg [127:0] key_m, key_s;
    reg [127:0] joy_m, joy_s;
    reg [63:0]  trig_m, trig_s;
    reg [2:0]   st_m, st_s;
    always @(posedge clk_sys) begin
        key_m  <= cont_key;  key_s  <= key_m;
        joy_m  <= cont_joy;  joy_s  <= joy_m;
        trig_m <= cont_trig; trig_s <= trig_m;
        st_m   <= {dataslot_allcomplete, osnotify_inmenu, rtc_valid}; st_s <= st_m;
    end

    reg  [63:0] mtime;
    reg  [63:0] mtimecmp;
    reg  [31:0] mtime_hi_latch;
    reg  [4:0]  irq_pend;
    reg  [4:0]  irq_en;
    reg  [15:0] key_prev;
    reg  [31:0] fb_addr;
    reg  [31:0] fb_active;
    reg         vid_fmt32, fmt_active;   // VID_CTRL bit 2: 1 = ABGR8888 scanout (switches at vblank with FB_ADDR)
    reg         fb_swap_pend;
    reg  [31:0] vid_frame;
    reg         in_vblank;

    wire        vblank_pulse, vactive_pulse;
    wire [7:0]  vid_line;
    wire        ds_irq_pulse;
    wire        blit_irq, mix_irq;

    reg timer_irq_r;                          // registered: 64-bit compare off the CPU path
    always @(posedge clk_sys) timer_irq_r <= (mtime >= mtimecmp);
    assign timer_irq = timer_irq_r;
    assign ext_irq   = |({mix_irq, blit_irq, irq_pend[4], irq_pend[1:0]} & {irq_en[3], irq_en[2], irq_en[4], irq_en[1:0]});

    reg         sys_ack_r;
    reg  [31:0] sys_dat_r;
    assign sys_ack = sys_ack_r;
    assign sys_dat = sys_dat_r;

    wire [11:0] sr = {m_adr[11:2], 2'b00};

    function [31:0] wmask(input [31:0] old, input [31:0] nw, input [3:0] sel);
        wmask = { sel[3] ? nw[31:24] : old[31:24], sel[2] ? nw[23:16] : old[23:16],
                  sel[1] ? nw[15:8]  : old[15:8],  sel[0] ? nw[7:0]   : old[7:0] };
    endfunction

always @(posedge clk_sys) begin
    sys_ack_r <= 1'b0;
    mtime <= mtime + 64'd1;

    if (rst_sys) begin
        mtime        <= 64'd0;
        mtimecmp     <= {64{1'b1}};
        irq_pend     <= 5'd0;
        irq_en       <= 5'd0;
        fb_addr      <= 32'h13F8_0000;
        fb_active    <= 32'h13F8_0000;
        fb_swap_pend <= 1'b0;
        vid_frame    <= 32'd0;
        vid_mode     <= 2'd2;           // M1 test pattern until firmware takes over
        vid_fmt32    <= 1'b0;           // RGB565 (M3 format) until firmware selects ABGR8888
        fmt_active   <= 1'b0;
        vid_border   <= 24'h000000;
        in_vblank    <= 1'b0;
        key_prev     <= 16'd0;
    end else begin
        // events
        if (vblank_pulse) begin
            irq_pend[0]  <= 1'b1;
            vid_frame    <= vid_frame + 32'd1;
            in_vblank    <= 1'b1;
            fb_active    <= fb_addr;
            fmt_active   <= vid_fmt32;
            fb_swap_pend <= 1'b0;
        end
        if (vactive_pulse) in_vblank <= 1'b0;
        if (ds_irq_pulse)  irq_pend[1] <= 1'b1;
        key_prev <= key_s[15:0];
        if (key_prev != key_s[15:0]) irq_pend[4] <= 1'b1;

        if (sel_sys && !sys_ack_r) begin
            sys_ack_r <= 1'b1;
            if (m_we) begin
                case (sr)
                12'h018: mtimecmp[31:0]  <= wmask(mtimecmp[31:0],  m_dat_w, m_sel);
                12'h01C: mtimecmp[63:32] <= wmask(mtimecmp[63:32], m_dat_w, m_sel);
                12'h020: irq_pend[4:0] <= irq_pend[4:0] & ~(m_dat_w[4:0] & 5'b10011);
                12'h024: irq_en <= m_dat_w[4:0];
                12'h108: begin fb_addr <= {m_dat_w[31:8], 8'd0}; fb_swap_pend <= 1'b1; end
                12'h110: begin vid_mode <= m_dat_w[1] ? 2'd2 : {1'b0, m_dat_w[0]}; vid_fmt32 <= m_dat_w[2]; end
                12'h114: vid_border <= m_dat_w[23:0];
                default: ;
                endcase
            end else begin
                case (sr)
                12'h000: sys_dat_r <= 32'h5546_3530;
                12'h004: sys_dat_r <= 32'h0003_0000;
                12'h008: sys_dat_r <= CLK_SYS_HZ;
                // cache sizes / ways of cpu/VexRiscv.v (localparams below), FPU-D, blitter/mixer presence
                12'h00C: sys_dat_r <= {5'd0, mix_present, blit_present, 1'b1, DCACHE_WAYS[3:0], ICACHE_WAYS[3:0],
                                       DCACHE_KB[7:0], ICACHE_KB[7:0]};
                12'h010: begin sys_dat_r <= mtime[31:0]; mtime_hi_latch <= mtime[63:32]; end
                12'h014: sys_dat_r <= mtime_hi_latch;
                12'h018: sys_dat_r <= mtimecmp[31:0];
                12'h01C: sys_dat_r <= mtimecmp[63:32];
                12'h020: sys_dat_r <= {27'd0, irq_pend[4], mix_irq, blit_irq, irq_pend[1:0]};
                12'h024: sys_dat_r <= {27'd0, irq_en};
                12'h030: sys_dat_r <= key_s[31:0];
                12'h034: sys_dat_r <= joy_s[31:0];
                12'h038: sys_dat_r <= {16'd0, trig_s[15:0]};
                12'h03C: sys_dat_r <= key_s[63:32];
                12'h040: sys_dat_r <= joy_s[63:32];
                12'h044: sys_dat_r <= {16'd0, trig_s[31:16]};
                12'h048: sys_dat_r <= key_s[95:64];
                12'h04C: sys_dat_r <= joy_s[95:64];
                12'h050: sys_dat_r <= {16'd0, trig_s[47:32]};
                12'h054: sys_dat_r <= key_s[127:96];
                12'h058: sys_dat_r <= joy_s[127:96];
                12'h05C: sys_dat_r <= {16'd0, trig_s[63:48]};
                12'h060: sys_dat_r <= rtc_epoch_seconds;    // quasi-static, read twice if paranoid
                12'h064: sys_dat_r <= {31'd0, st_s[0]};
                12'h070: sys_dat_r <= {30'd0, st_s[2], st_s[1]};
                12'h100: sys_dat_r <= {6'd0, 2'd0, vid_line, 14'd0, fb_swap_pend, in_vblank};
                12'h104: sys_dat_r <= vid_frame;
                12'h108: sys_dat_r <= fb_addr;
                12'h10C: sys_dat_r <= fb_active;
                12'h110: sys_dat_r <= {29'd0, vid_fmt32, vid_mode == 2'd2, vid_mode == 2'd1};
                12'h114: sys_dat_r <= {8'd0, vid_border};
                12'h120: sys_dat_r <= {31'd0, sd_init_done};
                // memory performance counters (MEMORY_MAP.md 3.1a)
                12'h200: sys_dat_r <= pc_i_n;
                12'h204: sys_dat_r <= pc_i_cyc;
                12'h208: sys_dat_r <= pc_d_n;
                12'h20C: sys_dat_r <= pc_d_cyc;
                12'h210: sys_dat_r <= pc_w_n;
                12'h214: sys_dat_r <= pc_w_stall;
                12'h218: sys_dat_r <= pc_io_n;
                12'h21C: sys_dat_r <= pc_io_cyc;
                12'h220: sys_dat_r <= pc_arb_wait;
                12'h224: sys_dat_r <= pc_d_wait;
                12'h240: sys_dat_r <= pc_own[0];
                12'h244: sys_dat_r <= pc_own[1];
                12'h248: sys_dat_r <= pc_own[2];
                12'h24C: sys_dat_r <= pc_own[3];
                12'h250: sys_dat_r <= pc_own[4];
                12'h254: sys_dat_r <= pc_own[5];
                default: sys_dat_r <= 32'd0;
                endcase
            end
        end
    end
end

// ===========================================================================
// Memory performance counters (sysregs 0x200-0x25C, read-only, free-running 32-bit, wrap)
// docs/MEMORY_MAP.md 3.1a. Nothing here feeds back into the datapath.
// ===========================================================================
    reg [31:0] pc_i_n, pc_i_cyc, pc_d_n, pc_d_cyc, pc_w_n, pc_w_stall, pc_io_n, pc_io_cyc, pc_arb_wait, pc_d_wait;
    reg [31:0] pc_own [0:5];
    wire       pc_i_go   = iBus_cmd_valid && iBus_cmd_ready && (iBus_cmd_payload_address[31:28] == 4'h1);
    wire       pc_d_sd   = (dBus_cmd_payload_address[31:28] == 4'h1) || (dBus_cmd_payload_address[31:28] == 4'h5);
    wire       pc_d_line = dBus_cmd_valid && !dBus_cmd_payload_wr && (dBus_cmd_payload_size == 3'd5) && pc_d_sd;
    wire       pc_d_io   = dBus_cmd_valid && !pc_d_line && !(dBus_cmd_payload_wr && pc_d_sd)
                           && (dBus_cmd_payload_address[31:28] != 4'h0);
    reg        pc_io_open;
    integer    pk;
always @(posedge clk_sys) begin
    if (rst_sys) begin
        pc_i_n <= 32'd0; pc_i_cyc <= 32'd0; pc_d_n <= 32'd0; pc_d_cyc <= 32'd0; pc_w_n <= 32'd0;
        pc_w_stall <= 32'd0; pc_io_n <= 32'd0; pc_io_cyc <= 32'd0; pc_arb_wait <= 32'd0; pc_d_wait <= 32'd0;
        pc_io_open <= 1'b0;
        for (pk = 0; pk < 6; pk = pk + 1) pc_own[pk] <= 32'd0;
    end else begin
        // I$ line refill from SDRAM: the accept cycle + every cycle in IB_SD (until the 8th beat)
        if (pc_i_go) pc_i_n <= pc_i_n + 32'd1;
        if (pc_i_go || ib_state == IB_SD) pc_i_cyc <= pc_i_cyc + 32'd1;
        // D$ line refill: from dBus cmd valid (incl. waiting for an earlier store) to the last beat
        if (pc_d_line && dBus_cmd_ready) pc_d_n <= pc_d_n + 32'd1;
        if (pc_d_line || (db_state == DB_SD_R && db_line)) pc_d_cyc <= pc_d_cyc + 32'd1;
        // SDRAM stores: commands accepted, and cycles a store waited to be accepted (CPU stalled)
        if (dBus_cmd_valid && dBus_cmd_payload_wr && pc_d_sd && dBus_cmd_ready) pc_w_n <= pc_w_n + 32'd1;
        if (dBus_cmd_valid && dBus_cmd_payload_wr && !dBus_cmd_ready) pc_w_stall <= pc_w_stall + 32'd1;
        // any dBus command waiting to be accepted (the fabric still busy with the previous one)
        if (dBus_cmd_valid && !dBus_cmd_ready) pc_d_wait <= pc_d_wait + 32'd1;
        // uncached reads (0x5xxx_xxxx) and MMIO accesses: valid -> response / done
        if (pc_d_io && dBus_cmd_ready) begin pc_io_n <= pc_io_n + 32'd1; pc_io_open <= 1'b1; end
        if (pc_d_io || pc_io_open) pc_io_cyc <= pc_io_cyc + 32'd1;
        if (pc_io_open && db_state == DB_IDLE && !(pc_d_io && dBus_cmd_ready)) pc_io_open <= 1'b0;
        // CPU ports waiting for an arbiter grant (another master or each other)
        if ((p_valid[3] && !p_ready[3]) || (p_valid[4] && !p_ready[4])) pc_arb_wait <= pc_arb_wait + 32'd1;
        // SDRAM busy cycles by owner (arbiter port: 0 video, 1 bridge, 2 mixer, 3 dBus, 4 iBus, 5 blitter)
        if (arb_busy) pc_own[arb_owner] <= pc_own[arb_owner] + 32'd1;
    end
end

// ===========================================================================
// Video scanout (SDRAM port 0)
// ===========================================================================
vid_scanout scan (
    .clk_sys(clk_sys), .rst_sys(rst_mem),
    .fb_base(fb_active[25:0]), .fmt32(fmt_active),
    .p_valid(p_valid[0]), .p_ready(p_ready[0]), .p_addr(p_addr[0*24 +: 24]), .p_len(p_len[0*6 +: 6]),
    .p_rvalid(p_rvalid[0]), .p_rdata(p_rdata),
    .vblank_pulse(vblank_pulse), .vactive_pulse(vactive_pulse), .line(vid_line),
    .clk_vid(clk_vid), .vid_x(vid_x), .vid_y(vid_y), .pix_rgb(vid_fb_rgb)
);
    assign p_we[0]             = 1'b0;
    assign p_wdata[0*32 +: 32] = 32'd0;
    assign p_wstrb[0*4 +: 4]   = 4'd0;

// ===========================================================================
// Bridge <-> SDRAM (SDRAM port 1): APF writes (slot loads) and reads (save write-back)
// ===========================================================================
    wire bridge_idle;
bridge_sdram bsd (
    .clk_74a(clk_74a), .bridge_addr(bridge_addr), .bridge_wr(bridge_wr), .bridge_wr_data(bridge_wr_data),
    .bridge_rd(bridge_rd), .bridge_rd_data(bridge_rd_data),
    .clk_sys(clk_sys), .rst_sys(rst_mem),
    .p_valid(p_valid[1]), .p_ready(p_ready[1]), .p_we(p_we[1]), .p_addr(p_addr[1*24 +: 24]), .p_len(p_len[1*6 +: 6]),
    .p_wdata(p_wdata[1*32 +: 32]), .p_wstrb(p_wstrb[1*4 +: 4]), .p_wready(p_wready[1]),
    .p_rdata(p_rdata), .p_rvalid(p_rvalid[1]),
    .snoop_we(c_valid & c_ready & c_we), .snoop_addr(c_addr),
    .idle(bridge_idle)
);

// ===========================================================================
// Data-slot controller (0x8001_0000)
// ===========================================================================
dataslot_ctrl dsc (
    .clk_sys(clk_sys), .rst_sys(rst_sys),
    .wb_adr(m_adr[15:2]), .wb_dat_w(m_dat_w), .wb_we(m_we), .wb_stb(sel_ds),
    .wb_dat_r(ds_dat), .wb_ack(ds_ack),
    .bridge_idle(bridge_idle), .done_pulse(ds_irq_pulse),
    .clk_74a(clk_74a),
    .target_dataslot_read(target_dataslot_read), .target_dataslot_write(target_dataslot_write),
    .target_dataslot_flush(target_dataslot_flush), .target_dataslot_id(target_dataslot_id),
    .target_dataslot_slotoffset(target_dataslot_slotoffset), .target_dataslot_bridgeaddr(target_dataslot_bridgeaddr),
    .target_dataslot_length(target_dataslot_length), .target_dataslot_ack(target_dataslot_ack),
    .target_dataslot_done(target_dataslot_done), .target_dataslot_err(target_dataslot_err),
    .datatable_addr(datatable_addr), .datatable_wren(datatable_wren), .datatable_data(datatable_data),
    .datatable_q(datatable_q),
    .allcomplete(st_s[2])
);

// ===========================================================================
// Blitter (0x8002_0000, SDRAM port 5 = X0) and audio mixer (0x8003_0000, port 2 = X1)
// ===========================================================================
    wire blit_present, mix_present;
    wire [15:0] mix_l, mix_r;

ufo50_blitter blit (
    .clk(clk_sys), .rst(rst_sys),
    .wb_adr(m_adr[15:2]), .wb_dat_w(m_dat_w), .wb_sel(m_sel), .wb_we(m_we),
    .wb_cyc(sel_blit), .wb_stb(sel_blit), .wb_dat_r(blit_dat), .wb_ack(blit_ack), .irq(blit_irq),
    .mem_cmd_valid(p_valid[5]), .mem_cmd_we(p_we[5]), .mem_cmd_addr(p_addr[5*24 +: 24]),
    .mem_cmd_len(p_len[5*6 +: 6]), .mem_wdata(p_wdata[5*32 +: 32]), .mem_wstrb(p_wstrb[5*4 +: 4]),
    .mem_cmd_ready(p_ready[5]), .mem_wready(p_wready[5]), .mem_rdata(p_rdata), .mem_rvalid(p_rvalid[5]),
    .present(blit_present)
);

ufo50_mixer mix (
    .clk(clk_sys), .rst(rst_sys),
    .wb_adr(m_adr[15:2]), .wb_dat_w(m_dat_w), .wb_sel(m_sel), .wb_we(m_we),
    .wb_cyc(sel_mix), .wb_stb(sel_mix), .wb_dat_r(mix_dat), .wb_ack(mix_ack), .irq(mix_irq),
    .mem_cmd_valid(p_valid[2]), .mem_cmd_we(p_we[2]), .mem_cmd_addr(p_addr[2*24 +: 24]),
    .mem_cmd_len(p_len[2*6 +: 6]), .mem_wdata(p_wdata[2*32 +: 32]), .mem_wstrb(p_wstrb[2*4 +: 4]),
    .mem_cmd_ready(p_ready[2]), .mem_wready(p_wready[2]), .mem_rdata(p_rdata), .mem_rvalid(p_rvalid[2]),
    .audio_tick(audio_tick), .audio_l(mix_l), .audio_r(mix_r),
    .present(mix_present)
);

    always @(posedge clk_sys)
        if (audio_tick) begin
            audio_l <= mix_l;
            audio_r <= mix_r;
        end

endmodule

`default_nettype wire
