//
// sdram_ctrl2x.v - SDR SDRAM controller with the SDRAM in its own clock domain at twice
// clk_sys (UFO50 Pocket SoC, M5).
//
// Same request port as sdram_ctrl.v (docs/MEMORY_MAP.md section 5: 1..64 beats of 32 bits
// within one 2 KB SDRAM row, write data pulled with wready, read data as rvalid pulses), but
// the SDRAM runs on clk_mem (115.5 MHz = 2 x 57.75 MHz, same PLL), CAS latency 3, so a
// 32-bit beat moves every clk_sys cycle instead of every second one.
//
//   clk_sys side : front-end. Accepts a command, pushes it into the command FIFO, and
//                  - write: pulls all beats (wready on consecutive cycles) into the write
//                    FIFO and is done ("posted write"); the arbiter is free right after.
//                  - read : returns the beats from the read FIFO as rvalid pulses.
//   clk_mem side : the SDRAM engine. Closed page: ACTIVE, NOP, n READ/WRITE (BL=2, one per
//                  two clocks, auto-precharge on the last), wait tRP/tWR/tRC. An access of n
//                  beats takes 2n + ~8 clk_mem = n + ~4 clk_sys cycles plus FIFO latency.
//   The domains only meet in three dual-clock FIFOs (gray-code pointers, 2-flop
//   synchronisers) and in 2-flop synchronisers for init_done; core_constraints.sdc declares
//   the two clocks asynchronous for timing analysis, so nothing else may cross.
//
// Requests stay in order (one command FIFO); a read issued after a posted write sees its
// data. The engine only starts a read when the read FIFO has room for the whole burst, and
// the front-end only accepts a write when the write FIFO has room for all its beats.
//
// SDRAM pin timing (the part simulation cannot check): commands/data are launched on
// posedge clk_mem from IO registers, dram_clk = ~clk_mem through a DDIO output (core_top),
// so the SDRAM samples half a clk_mem period after launch. Read data for a READ registered
// at edge t0 is valid at the FPGA from about t0 + 3.1 T to t0 + 3.9 T (tAC 5.4 ns, tOH 2.7 ns
// at CL3, ~1 ns board delay each way, T = 8.66 ns) and is captured on the negedge at
// t0 + 3.5 T, i.e. the same structure as sdram_ctrl.v at CL2 and 57.75 MHz.
//
// Timing at 115.5 MHz (T = 8.66 ns), for -6/-7 parts at CL3: tRCD 2 clk, tRP 2 clk,
// tRC 7 clk, tRAS 5 clk, tWR 2 clk, tRFC 7 clk (8 used); refresh every 600 clk_mem (5.2 us).
//
`default_nettype none

// ------------------------------------------------------------------ dual-clock FIFO
// First-word-fall-through: r_valid/r_data show the head; r_pop consumes it.
// Timing (115.5 MHz side): the head is a register loaded by a synchronous RAM read (no
// combinational read mux on r_data), and the synchronised gray pointers are converted to
// binary in their own register stage, so no gray->binary chain feeds the count arithmetic.
module afifo #(
    parameter W  = 32,
    parameter AW = 4                       // depth 2^AW
)(
    input  wire          w_clk,
    input  wire          w_rst,
    input  wire          w_push,
    input  wire [W-1:0]  w_data,
    output reg  [AW:0]   w_free,           // entries free (conservative: lags pops)
    input  wire          r_clk,
    input  wire          r_rst,
    input  wire          r_pop,
    output wire          r_valid,
    output wire [W-1:0]  r_data,
    output reg  [AW:0]   r_count           // entries available (conservative: lags pushes)
);
    reg [W-1:0] mem [0:(1<<AW)-1];
    reg [AW:0]  wp_bin, wp_gray, rp_bin, rp_gray;
    reg [AW:0]  wp_gray_s1, wp_gray_s2, rp_gray_s1, rp_gray_s2;
    reg [AW:0]  wp_bin_s, rp_bin_s;                  // synchronised pointers, binary
    reg [W-1:0] head;

    function [AW:0] g2b(input [AW:0] g);
        integer i;
        begin
            g2b[AW] = g[AW];
            for (i = AW - 1; i >= 0; i = i - 1) g2b[i] = g2b[i + 1] ^ g[i];
        end
    endfunction

    // write side
    wire [AW:0] wp_next = wp_bin + 1'b1;
    always @(posedge w_clk) begin
        if (w_push) mem[wp_bin[AW-1:0]] <= w_data;
        if (w_rst) begin wp_bin <= 0; wp_gray <= 0; rp_gray_s1 <= 0; rp_gray_s2 <= 0; rp_bin_s <= 0; w_free <= (1 << AW); end
        else begin
            if (w_push) begin wp_bin <= wp_next; wp_gray <= wp_next ^ (wp_next >> 1); end
            rp_gray_s1 <= rp_gray; rp_gray_s2 <= rp_gray_s1; rp_bin_s <= g2b(rp_gray_s2);
            w_free <= (1 << AW) - ((w_push ? wp_next : wp_bin) - rp_bin_s);
        end
    end

    // read side
    // The head register always holds mem[rp] (the RAM address is the pointer after this
    // cycle's pop). An entry is counted only after its write pointer has crossed the two
    // synchronisers and the binary stage, i.e. >= 3 r_clk edges after the RAM write, so the
    // head read sees the written data by the time r_valid shows it.
    wire        pop     = r_pop && r_valid;
    wire [AW:0] rp_next = rp_bin + 1'b1;
    wire [AW:0] rp_now  = pop ? rp_next : rp_bin;
    assign r_valid = (r_count != 0);
    assign r_data  = head;
    always @(posedge r_clk) begin
        head <= mem[rp_now[AW-1:0]];
        if (r_rst) begin rp_bin <= 0; rp_gray <= 0; wp_gray_s1 <= 0; wp_gray_s2 <= 0; wp_bin_s <= 0; r_count <= 0; end
        else begin
            if (pop) begin rp_bin <= rp_next; rp_gray <= rp_next ^ (rp_next >> 1); end
            wp_gray_s1 <= wp_gray; wp_gray_s2 <= wp_gray_s1; wp_bin_s <= g2b(wp_gray_s2);
            r_count <= wp_bin_s - rp_now;
        end
    end
endmodule

// ------------------------------------------------------------------ controller
module sdram_ctrl2x #(
    parameter INIT_CYCLES    = 16'd23100,   // clk_mem cycles, >= 200 us at 115.5 MHz
    parameter REFRESH_CYCLES = 11'd600      // clk_mem cycles (5.2 us)
)(
    // ---- clk_sys side (same port as sdram_ctrl)
    input  wire        clk,
    input  wire        rst,
    input  wire        cmd_valid,
    output wire        cmd_ready,
    input  wire        cmd_we,
    input  wire [25:2] cmd_addr,
    input  wire [5:0]  cmd_len,
    input  wire [31:0] wdata,
    input  wire [3:0]  wstrb,
    output wire        wready,
    output reg  [31:0] rdata,
    output reg         rvalid,
    output wire        idle,
    output reg         init_done,

    // ---- clk_mem side
    input  wire        clk_mem,
    output reg  [12:0] sd_a,
    output reg  [1:0]  sd_ba,
    output reg  [1:0]  sd_dqm,
    output reg         sd_cke,
    output reg         sd_ras_n,
    output reg         sd_cas_n,
    output reg         sd_we_n,
    output reg  [15:0] sd_dq_out,
    output reg         sd_dq_oe,
    input  wire [15:0] sd_dq_in
);
    // -------------------------------------------------------------- resets
    reg [2:0] mrst_s = 3'b111;                       // rst into clk_mem
    always @(posedge clk_mem) mrst_s <= {mrst_s[1:0], rst};
    wire mrst = mrst_s[2];
    reg       m_init_done;
    reg [1:0] init_s;
    always @(posedge clk) begin
        init_s <= {init_s[0], m_init_done};
        init_done <= rst ? 1'b0 : init_s[1];
    end

    // -------------------------------------------------------------- FIFOs
    // command: {we, addr[25:2], len}
    wire        cq_push;  wire [30:0] cq_wd = {cmd_we, cmd_addr, cmd_len};
    wire [2:0]  cq_free;
    wire        cq_pop, cq_valid; wire [30:0] cq_rd; wire [2:0] cq_count;
    afifo #(.W(31), .AW(2)) cq (.w_clk(clk), .w_rst(rst), .w_push(cq_push), .w_data(cq_wd), .w_free(cq_free),
        .r_clk(clk_mem), .r_rst(mrst), .r_pop(cq_pop), .r_valid(cq_valid), .r_data(cq_rd), .r_count(cq_count));
    // write data: {strb, data}
    wire        wq_push;  wire [6:0] wq_free;
    wire        wq_pop, wq_valid; wire [35:0] wq_rd; wire [6:0] wq_count;
    afifo #(.W(36), .AW(6)) wq (.w_clk(clk), .w_rst(rst), .w_push(wq_push), .w_data({wstrb, wdata}), .w_free(wq_free),
        .r_clk(clk_mem), .r_rst(mrst), .r_pop(wq_pop), .r_valid(wq_valid), .r_data(wq_rd), .r_count(wq_count));
    // read data
    reg         rq_push;  reg [31:0] rq_wd; wire [6:0] rq_free;
    wire        rq_pop, rq_valid; wire [31:0] rq_rd; wire [6:0] rq_count;
    afifo #(.W(32), .AW(6)) rq (.w_clk(clk_mem), .w_rst(mrst), .w_push(rq_push), .w_data(rq_wd), .w_free(rq_free),
        .r_clk(clk), .r_rst(rst), .r_pop(rq_pop), .r_valid(rq_valid), .r_data(rq_rd), .r_count(rq_count));

    // -------------------------------------------------------------- clk_sys front-end
    localparam F_IDLE = 2'd0, F_WBEATS = 2'd1, F_RBEATS = 2'd2;
    reg [1:0] fe;
    reg [5:0] f_left;                                 // beats left - 1
    wire      room = (cq_free != 3'd0) && (!cmd_we || {1'b0, wq_free} >= {2'b00, cmd_len} + 8'd1);
    assign cmd_ready = (fe == F_IDLE) && init_done && cmd_valid && room;
    assign cq_push   = cmd_valid && cmd_ready;
    assign wready    = (fe == F_WBEATS);
    assign wq_push   = (fe == F_WBEATS);
    assign rq_pop    = (fe == F_RBEATS) && rq_valid;
    assign idle      = (fe == F_IDLE) && (cq_free == 3'd4) && !rq_valid;
    always @(posedge clk) begin
        rvalid <= 1'b0;
        if (rq_pop) begin rdata <= rq_rd; rvalid <= 1'b1; end
        if (rst) fe <= F_IDLE;
        else case (fe)
            F_IDLE: if (cq_push) begin f_left <= cmd_len; fe <= cmd_we ? F_WBEATS : F_RBEATS; end
            F_WBEATS: if (f_left == 6'd0) fe <= F_IDLE; else f_left <= f_left - 6'd1;
            F_RBEATS: if (rq_pop) begin if (f_left == 6'd0) fe <= F_IDLE; else f_left <= f_left - 6'd1; end
            default: fe <= F_IDLE;
        endcase
    end

    // -------------------------------------------------------------- clk_mem SDRAM engine
    localparam [2:0] C_NOP = 3'b111, C_ACT = 3'b011, C_RD = 3'b101, C_WR = 3'b100,
                     C_PRE = 3'b010, C_REF = 3'b001, C_MRS = 3'b000;
    localparam [3:0] S_INIT = 4'd0, S_INIT_PRE = 4'd1, S_INIT_REF = 4'd2, S_INIT_MRS = 4'd3,
                     S_IDLE = 4'd4, S_ACT = 4'd6, S_RD = 4'd7, S_WR = 4'd8, S_WAIT = 4'd9;
    reg [3:0]  state;
    reg [15:0] cnt;
    reg [3:0]  refs;
    reg [10:0] ref_cnt;
    reg        ref_due;
    reg        a_we;
    reg [25:2] a_addr;
    reg [5:0]  a_left;
    reg        phase;
    reg [15:0] wr_hi; reg [1:0] wr_dqm_hi;
    reg [3:0]  rc_cnt;                                 // clocks since ACTIVE (tRC)

    // read capture: negedge IO register, then a second negedge register in the core (the
    // IO-cell -> core transfer gets a full period; at 115.5 MHz the direct half-period hop
    // failed timing by ~1.6 ns), then posedge (core-to-core, placeable adjacently)
    reg [15:0] dq_neg  /* synthesis preserve */;
    reg [15:0] dq_neg2 /* synthesis preserve */;
    always @(negedge clk_mem) begin dq_neg <= sd_dq_in; dq_neg2 <= dq_neg; end
    reg [15:0] dq_pos;
    always @(posedge clk_mem) dq_pos <= dq_neg2;
    // tag per READ: lo halfword in dq_pos 6 clocks after the READ was registered, hi 7
    reg [7:0]  rd_pipe;
    reg [15:0] rd_lo;

    task sdcmd(input [2:0] c);
        {sd_ras_n, sd_cas_n, sd_we_n} <= c;
    endtask
    wire [9:0] col = {a_addr[10:2], 1'b0};
    wire       start_ok = cq_valid && (cq_rd[30] || ({1'b0, rq_free} >= {2'b00, cq_rd[5:0]} + 8'd1));
    assign cq_pop = (state == S_IDLE) && !ref_due && m_init_done && start_ok && (rc_cnt == 4'd0);
    assign wq_pop = (state == S_WR) && !phase && wq_valid;

    always @(posedge clk_mem) begin
        sdcmd(C_NOP);
        sd_dq_oe <= 1'b0;
        rq_push  <= 1'b0;
        if (rc_cnt != 4'd0) rc_cnt <= rc_cnt - 4'd1;

        if (ref_cnt == 11'd0) begin
            ref_cnt <= REFRESH_CYCLES;
            if (m_init_done) ref_due <= 1'b1;
        end else
            ref_cnt <= ref_cnt - 11'd1;

        rd_pipe <= {rd_pipe[6:0], 1'b0};
        if (rd_pipe[5]) rd_lo <= dq_pos;
        if (rd_pipe[6]) begin rq_wd <= {dq_pos, rd_lo}; rq_push <= 1'b1; end

        if (mrst) begin
            state       <= S_INIT;
            cnt         <= INIT_CYCLES;
            m_init_done <= 1'b0;
            ref_due     <= 1'b0;
            ref_cnt     <= REFRESH_CYCLES;
            sd_cke      <= 1'b0;
            sd_dqm      <= 2'b11;
            sd_a        <= 13'd0;
            sd_ba       <= 2'd0;
            rd_pipe     <= 8'd0;
            phase       <= 1'b0;
            rc_cnt      <= 4'd0;
        end else begin
            case (state)
            S_INIT: begin
                sd_cke <= 1'b1;
                sd_dqm <= 2'b11;
                if (cnt == 16'd0) begin
                    sdcmd(C_PRE);
                    sd_a[10] <= 1'b1;                    // all banks
                    cnt   <= 16'd4;
                    state <= S_INIT_PRE;
                end else
                    cnt <= cnt - 16'd1;
            end
            S_INIT_PRE: begin
                if (cnt == 16'd0) begin refs <= 4'd8; cnt <= 16'd0; state <= S_INIT_REF; end
                else cnt <= cnt - 16'd1;
            end
            S_INIT_REF: begin
                if (cnt == 16'd0) begin
                    if (refs == 4'd0) begin
                        sdcmd(C_MRS);
                        sd_ba <= 2'b00;
                        // burst write = programmed BL, CL=3, sequential, BL=2
                        sd_a  <= 13'b000_0_00_011_0_001;
                        cnt   <= 16'd4;
                        state <= S_INIT_MRS;
                    end else begin
                        sdcmd(C_REF);
                        refs <= refs - 4'd1;
                        cnt  <= 16'd9;                    // tRFC (60 ns = 7 clk)
                    end
                end else
                    cnt <= cnt - 16'd1;
            end
            S_INIT_MRS: begin
                if (cnt == 16'd0) begin m_init_done <= 1'b1; state <= S_IDLE; end
                else cnt <= cnt - 16'd1;
            end

            S_IDLE: begin
                sd_dqm <= 2'b11;
                if (ref_due && m_init_done && rc_cnt == 4'd0) begin
                    ref_due <= 1'b0;
                    sdcmd(C_REF);
                    cnt   <= 16'd8;                       // tRFC
                    state <= S_WAIT;
                end else if (cq_pop) begin
                    a_we   <= cq_rd[30];
                    a_addr <= cq_rd[29:6];
                    a_left <= cq_rd[5:0];
                    sdcmd(C_ACT);
                    sd_ba  <= cq_rd[16:15];               // addr[12:11]
                    sd_a   <= cq_rd[29:17];               // addr[25:13]
                    rc_cnt <= 4'd7;                       // tRC
                    state  <= S_ACT;
                end
            end

            S_ACT: begin                                  // tRCD: one NOP between ACT and RD/WR
                phase <= 1'b0;
                state <= a_we ? S_WR : S_RD;
            end

            S_RD: begin
                if (!phase) begin
                    sdcmd(C_RD);
                    sd_dqm     <= 2'b00;
                    sd_a       <= {2'b00, (a_left == 6'd0), col};
                    rd_pipe[0] <= 1'b1;
                    phase      <= 1'b1;
                end else begin
                    phase <= 1'b0;
                    if (a_left == 6'd0) begin
                        cnt   <= 16'd2;                   // burst end + tRP
                        state <= S_WAIT;
                    end else begin
                        a_left <= a_left - 6'd1;
                        a_addr[10:2] <= a_addr[10:2] + 9'd1;
                    end
                end
            end

            S_WR: begin
                if (!phase) begin
                    if (wq_valid) begin                   // otherwise wait (row stays open)
                        sd_dq_oe  <= 1'b1;
                        sdcmd(C_WR);
                        sd_a      <= {2'b00, (a_left == 6'd0), col};
                        sd_dq_out <= wq_rd[15:0];
                        sd_dqm    <= ~wq_rd[33:32];
                        wr_hi     <= wq_rd[31:16];
                        wr_dqm_hi <= ~wq_rd[35:34];
                        phase     <= 1'b1;
                    end else
                        sd_dqm <= 2'b11;
                end else begin
                    sd_dq_oe  <= 1'b1;
                    sd_dq_out <= wr_hi;
                    sd_dqm    <= wr_dqm_hi;
                    phase     <= 1'b0;
                    if (a_left == 6'd0) begin
                        cnt   <= 16'd3;                   // tWR + tRP after the last data
                        state <= S_WAIT;
                    end else begin
                        a_left <= a_left - 6'd1;
                        a_addr[10:2] <= a_addr[10:2] + 9'd1;
                    end
                end
            end

            S_WAIT: begin
                sd_dqm <= 2'b11;
                if (cnt == 16'd0) state <= S_IDLE;
                else cnt <= cnt - 16'd1;
            end
            default: state <= S_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
