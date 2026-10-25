//
// sdram_ctrl.v - single-port SDR SDRAM controller for the Pocket's 512 Mbit x16 SDRAM
//
// UFO50 Pocket SoC (M3). Closed-page: every access is ACTIVE, 1..8 READ/WRITE
// commands (burst length 2 = one 32-bit beat each, issued every 2 clocks so data
// streams without gaps), the last one with auto-precharge.
//
// Geometry: 4 banks x 8192 rows x 1024 columns x 16 bit = 64 MB.
// Byte address [25:0]: col = [10:1], bank = [12:11], row = [25:13].
// A burst must stay inside an aligned 32-byte block (never crosses a row).
//
// Clocking (see docs/MEMORY_MAP.md and BUILDING.md):
//   - commands/addresses/write data are launched on posedge clk from IO registers
//   - dram_clk = ~clk, driven through a DDIO output (soc top), so the SDRAM samples
//     half a clock after launch (~P/2 setup and hold for any IO delay)
//   - read data is captured on NEGEDGE clk (dq_in_neg, in this module), which
//     lands in the middle of the CL=2 data window at 57.75 MHz
//
// Timing at 57.75 MHz (P = 17.3 ns), conservative for -6/-7 parts:
//   tRCD = 2 clk, tRP = 2 clk, tRC >= 6 clk, tRFC = 8 clk, CL = 2, tWR+tRP = 4 clk
//   refresh every REFRESH_CYCLES (384 clk = 6.6 us; 8192 rows per 54 ms)
//
`default_nettype none

module sdram_ctrl #(
    parameter INIT_CYCLES    = 16'd12000,   // >= 200 us at 57.75 MHz
    parameter REFRESH_CYCLES = 10'd384
)(
    input  wire        clk,
    input  wire        rst,             // synchronous, active high (PLL not locked)

    // request port
    input  wire        cmd_valid,
    output wire        cmd_ready,       // pulses in the cycle the command is accepted
    input  wire        cmd_we,
    input  wire [25:2] cmd_addr,
    input  wire [2:0]  cmd_len,         // beats - 1
    input  wire [31:0] wdata,
    input  wire [3:0]  wstrb,
    output wire        wready,          // current beat consumed this cycle
    output reg  [31:0] rdata,
    output reg         rvalid,
    output wire        idle,            // no access in progress (for arbiter)
    output reg         init_done,

    // SDRAM pins (registered here; place in IO cells)
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

// command encoding {ras_n, cas_n, we_n}
localparam [2:0] C_NOP = 3'b111, C_ACT = 3'b011, C_RD = 3'b101, C_WR = 3'b100,
                 C_PRE = 3'b010, C_REF = 3'b001, C_MRS = 3'b000;

localparam [3:0] S_INIT = 4'd0, S_INIT_PRE = 4'd1, S_INIT_REF = 4'd2, S_INIT_MRS = 4'd3,
                 S_IDLE = 4'd4, S_REF = 4'd5, S_ACT = 4'd6, S_RD = 4'd7, S_WR = 4'd8,
                 S_WAIT = 4'd9;

    reg [3:0]  state;
    reg [15:0] cnt;
    reg [3:0]  refs;
    reg [9:0]  ref_cnt;
    reg        ref_due;

    reg        a_we;
    reg [25:2] a_addr;
    reg [2:0]  a_left;      // beats remaining - 1
    reg        phase;       // 0 = command cycle, 1 = second data cycle
    reg [15:0] wr_hi;
    reg [1:0]  wr_dqm_hi;

    // read data capture: negedge IO register, then posedge
    reg [15:0] dq_neg;
    always @(negedge clk) dq_neg <= sd_dq_in;
    reg [15:0] dq_pos;
    always @(posedge clk) dq_pos <= dq_neg;

    // read return pipeline: tag bit per issued READ; data lo halfword is in dq_pos
    // 4 clocks after the READ was registered, hi halfword 5 clocks after.
    reg [5:0]  rd_pipe;
    reg [15:0] rd_lo;

    assign cmd_ready = (state == S_IDLE) && !ref_due && cmd_valid && init_done;
    assign wready    = (state == S_WR) && !phase;
    assign idle      = (state == S_IDLE) && (rd_pipe == 6'd0);

    task sdcmd(input [2:0] c);
        {sd_ras_n, sd_cas_n, sd_we_n} <= c;
    endtask

    wire [9:0] col = {a_addr[10:2], 1'b0};

always @(posedge clk) begin
    // defaults
    sdcmd(C_NOP);
    sd_dq_oe <= 1'b0;
    rvalid   <= 1'b0;

    // refresh timer
    if (ref_cnt == 10'd0) begin
        ref_cnt <= REFRESH_CYCLES;
        if (init_done) ref_due <= 1'b1;
    end else
        ref_cnt <= ref_cnt - 10'd1;

    // read data return
    rd_pipe <= {rd_pipe[4:0], 1'b0};
    if (rd_pipe[3]) rd_lo <= dq_pos;
    if (rd_pipe[4]) begin
        rdata  <= {dq_pos, rd_lo};
        rvalid <= 1'b1;
    end

    if (rst) begin
        state     <= S_INIT;
        cnt       <= INIT_CYCLES;
        init_done <= 1'b0;
        ref_due   <= 1'b0;
        ref_cnt   <= REFRESH_CYCLES;
        sd_cke    <= 1'b0;
        sd_dqm    <= 2'b11;
        sd_a      <= 13'd0;
        sd_ba     <= 2'd0;
        rd_pipe   <= 6'd0;
        phase     <= 1'b0;
    end else begin
        case (state)
        S_INIT: begin
            sd_cke <= 1'b1;
            sd_dqm <= 2'b11;
            if (cnt == 16'd0) begin
                sdcmd(C_PRE);
                sd_a[10] <= 1'b1;            // all banks
                cnt   <= 16'd4;
                state <= S_INIT_PRE;
            end else
                cnt <= cnt - 16'd1;
        end
        S_INIT_PRE: begin
            if (cnt == 16'd0) begin
                refs  <= 4'd8;
                cnt   <= 16'd0;
                state <= S_INIT_REF;
            end else
                cnt <= cnt - 16'd1;
        end
        S_INIT_REF: begin
            if (cnt == 16'd0) begin
                if (refs == 4'd0) begin
                    sdcmd(C_MRS);
                    sd_ba <= 2'b00;
                    // burst write = programmed BL, CL=2, sequential, BL=2
                    sd_a  <= 13'b000_0_00_010_0_001;
                    cnt   <= 16'd4;
                    state <= S_INIT_MRS;
                end else begin
                    sdcmd(C_REF);
                    refs <= refs - 4'd1;
                    cnt  <= 16'd9;
                end
            end else
                cnt <= cnt - 16'd1;
        end
        S_INIT_MRS: begin
            if (cnt == 16'd0) begin
                init_done <= 1'b1;
                state     <= S_IDLE;
            end else
                cnt <= cnt - 16'd1;
        end

        S_IDLE: begin
            sd_dqm <= 2'b11;
            if (ref_due && init_done) begin
                ref_due <= 1'b0;
                sdcmd(C_REF);
                cnt   <= 16'd7;
                state <= S_WAIT;
            end else if (cmd_valid && init_done) begin
                a_we   <= cmd_we;
                a_addr <= cmd_addr;
                a_left <= cmd_len;
                sdcmd(C_ACT);
                sd_ba  <= cmd_addr[12:11];
                sd_a   <= cmd_addr[25:13];
                state  <= S_ACT;
            end
        end

        S_ACT: begin                         // tRCD: one NOP between ACT and RD/WR
            phase <= 1'b0;
            state <= a_we ? S_WR : S_RD;
        end

        S_RD: begin
            if (!phase) begin
                sdcmd(C_RD);
                sd_dqm   <= 2'b00;
                sd_a     <= {2'b00, (a_left == 3'd0), col};
                rd_pipe[0] <= 1'b1;
                phase    <= 1'b1;
            end else begin
                phase <= 1'b0;
                if (a_left == 3'd0) begin
                    cnt   <= 16'd4;              // precharge + last data
                    state <= S_WAIT;
                end else begin
                    a_left <= a_left - 3'd1;
                    a_addr[4:2] <= a_addr[4:2] + 3'd1;
                end
            end
        end

        S_WR: begin
            sd_dq_oe <= 1'b1;
            if (!phase) begin
                sdcmd(C_WR);
                sd_a      <= {2'b00, (a_left == 3'd0), col};
                sd_dq_out <= wdata[15:0];
                sd_dqm    <= ~wstrb[1:0];
                wr_hi     <= wdata[31:16];
                wr_dqm_hi <= ~wstrb[3:2];
                phase     <= 1'b1;
            end else begin
                sd_dq_out <= wr_hi;
                sd_dqm    <= wr_dqm_hi;
                phase     <= 1'b0;
                if (a_left == 3'd0) begin
                    cnt   <= 16'd4;              // tWR + tRP
                    state <= S_WAIT;
                end else begin
                    a_left <= a_left - 3'd1;
                    a_addr[4:2] <= a_addr[4:2] + 3'd1;
                end
            end
        end

        S_WAIT: begin
            sd_dqm <= 2'b11;
            if (cnt == 16'd0)
                state <= S_IDLE;
            else
                cnt <= cnt - 16'd1;
        end

        default: state <= S_IDLE;
        endcase
    end
end

endmodule

`default_nettype wire
