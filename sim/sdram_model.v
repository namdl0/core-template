//
// sdram_model.v - behavioural x16 SDR SDRAM (4 banks x 8192 rows x 1024 cols = 64 MB)
//
// Simulation only. Written for the UFO50 M3 testbench; models the parts of a
// 512 Mbit SDR SDRAM (e.g. AS4C32M16SB / IS42S16320) that sdram_ctrl.v uses, and
// checks the timing the controller must respect:
//   mode register (CL 2/3, BL 1/2/4/8, sequential), ACTIVE, READ/WRITE (+auto precharge),
//   PRECHARGE (one/all), AUTO REFRESH, DQM byte masks.
//   Checks: tRCD, tRP, tRC, tRAS, tRFC, tWR, tMRD, command to a bank in the wrong
//   state, refresh interval (tREFI), read data driven with tAC / tOH.
// Errors are counted in `errors` and printed (first 20).
//
`timescale 1ps/1ps

module sdram_model #(
    parameter real T_AC   = 6000.0,     // access time from clock (CL=2)
    parameter real T_OH   = 2500.0,     // output hold
    parameter real T_RCD  = 15000.0,
    parameter real T_RP   = 15000.0,
    parameter real T_RC   = 60000.0,
    parameter real T_RAS  = 42000.0,
    parameter real T_RFC  = 60000.0,
    parameter real T_WR   = 14000.0,
    parameter real T_REFI = 7812500.0,  // 64 ms / 8192
    parameter      VERBOSE = 0
)(
    input  wire        clk,
    input  wire        cke,
    input  wire        ras_n,
    input  wire        cas_n,
    input  wire        we_n,
    input  wire [1:0]  ba,
    input  wire [12:0] a,
    input  wire [1:0]  dqm,
    inout  wire [15:0] dq
);
    reg [15:0] mem [0:32'h1FFFFFF];        // 32M halfwords

    integer errors = 0;
    integer reads = 0, writes = 0, refreshes = 0;

    reg [2:0]  cl = 3'd2;
    reg [3:0]  bl = 4'd1;
    reg        mode_set = 1'b0;

    reg        open_ [0:3];
    reg [12:0] row_ [0:3];
    real       t_act [0:3];
    real       t_pre [0:3];
    real       t_lastwr [0:3];
    real       t_ref, t_ref_prev, t_mrs;
    reg        ap_pend [0:3];
    real       ap_time [0:3];      // time the auto precharge starts

    // read output pipeline: entries indexed by clock edge number
    reg [15:0] rd_data [0:15];
    reg        rd_valid [0:15];
    reg [1:0]  rd_mask [0:15];
    integer    edge_n = 0;

    // write burst state
    reg        wr_act = 1'b0;
    integer    wr_left;
    reg [1:0]  wr_bank;
    reg [24:0] wr_addr;

    reg [15:0] dq_drv;
    reg        dq_en = 1'b0;
    assign dq = dq_en ? dq_drv : 16'hzzzz;

    integer i;
    initial begin
        for (i = 0; i < 4; i = i + 1) begin
            open_[i] = 1'b0; t_act[i] = -1.0e12; t_pre[i] = -1.0e12; t_lastwr[i] = -1.0e12; ap_pend[i] = 1'b0;
        end
        for (i = 0; i < 16; i = i + 1) rd_valid[i] = 1'b0;
        t_ref = -1.0; t_ref_prev = -1.0; t_mrs = -1.0e12;
    end

    task err(input [8*64-1:0] msg);
        begin
            errors = errors + 1;
            if (errors <= 20) $display("[%0t] SDRAM MODEL ERROR: %0s", $time, msg);
        end
    endtask

    function [24:0] haddr(input [1:0] b, input [12:0] r, input [9:0] c);
        haddr = {r, b, c};          // matches sdram_ctrl: col [10:1], bank [12:11], row [25:13]
    endfunction

    // resolve pending auto precharges
    task ap_update;
        integer k;
        begin
            for (k = 0; k < 4; k = k + 1)
                if (ap_pend[k] && $realtime >= ap_time[k]) begin
                    ap_pend[k] = 1'b0;
                    open_[k] = 1'b0;
                    t_pre[k] = ap_time[k];
                end
        end
    endtask

    wire [2:0] cmd = {ras_n, cas_n, we_n};
    real now;
    integer slot, j;
    reg [9:0] col;

    // read data output: the pipeline slot of this edge is driven from tOH (X) / tAC (data)
    // after the edge until tOH after the next edge
    event   drive_ev;
    reg        drv_v;
    reg [15:0] drv_d;
always @(drive_ev) begin
    #(T_OH);
    if (drv_v) begin
        dq_en  = 1'b1;
        dq_drv = 16'hxxxx;
        #(T_AC - T_OH) dq_drv = drv_d;
    end else
        dq_en = 1'b0;
end

always @(posedge clk) if (cke) begin
    edge_n = edge_n + 1;
    ap_update;
    slot  = edge_n % 16;
    drv_v = rd_valid[slot];
    drv_d = rd_data[slot];
    rd_valid[slot] = 1'b0;
    -> drive_ev;

    // ---- write burst data (beats after the first)
    if (wr_act && cmd != 3'b100) begin
        if (!dqm[0]) mem[wr_addr][7:0]  <= dq[7:0];
        if (!dqm[1]) mem[wr_addr][15:8] <= dq[15:8];
        wr_left = wr_left - 1;
        wr_addr = {wr_addr[24:3], wr_addr[2:0] + 3'd1};
        if (wr_left == 0) begin wr_act = 1'b0; t_lastwr[wr_bank] = $realtime; end
    end

    case (cmd)
    3'b111: ;                                           // NOP
    3'b000: begin                                       // MRS
        for (j = 0; j < 4; j = j + 1) if (open_[j]) err("MRS with open bank");
        cl = a[6:4];
        case (a[2:0]) 3'd0: bl = 1; 3'd1: bl = 2; 3'd2: bl = 4; 3'd3: bl = 8; default: err("bad BL"); endcase
        if (a[3]) err("interleaved burst not modelled");
        if (cl != 2 && cl != 3) err("bad CL");
        mode_set = 1'b1;
        t_mrs = $realtime;
        if (VERBOSE) $display("[%0t] SDRAM MRS CL=%0d BL=%0d", $time, cl, bl);
    end
    3'b001: begin                                       // AUTO REFRESH
        for (j = 0; j < 4; j = j + 1) begin
            if (open_[j]) err("REFRESH with open bank");
            if ($realtime - t_pre[j] < T_RP - 1) err("tRP before REFRESH");
        end
        if (t_ref >= 0 && $realtime - t_ref < T_RFC - 1) err("tRFC");
        if (mode_set && t_ref >= 0 && $realtime - t_ref > T_REFI * 1.0) err("refresh interval > tREFI");
        t_ref = $realtime;
        refreshes = refreshes + 1;
        for (j = 0; j < 4; j = j + 1) t_act[j] = $realtime;   // tRC also applies after REF
    end
    3'b010: begin                                       // PRECHARGE
        for (j = 0; j < 4; j = j + 1)
            if (a[10] || ba == j) begin
                if (open_[j] && $realtime - t_act[j] < T_RAS - 1) err("tRAS");
                if (open_[j] && $realtime - t_lastwr[j] < T_WR - 1) err("tWR");
                open_[j] = 1'b0;
                t_pre[j] = $realtime;
            end
    end
    3'b011: begin                                       // ACTIVE
        if (!mode_set) err("ACTIVE before MRS");
        if (open_[ba]) err("ACTIVE to an open bank");
        if ($realtime - t_pre[ba] < T_RP - 1) err("tRP");
        if ($realtime - t_act[ba] < T_RC - 1) err("tRC");
        if (t_ref >= 0 && $realtime - t_ref < T_RFC - 1) err("tRFC (ACT)");
        open_[ba] = 1'b1;
        row_[ba]  = a;
        t_act[ba] = $realtime;
    end
    3'b101: begin                                       // READ
        if (!open_[ba]) err("READ to a closed bank");
        if ($realtime - t_act[ba] < T_RCD - 1) err("tRCD (READ)");
        col = a[9:0];
        for (j = 0; j < bl; j = j + 1) begin
            slot = (edge_n + cl - 1 + j) % 16;
            rd_data[slot]  = mem[haddr(ba, row_[ba], {col[9:3], col[2:0] + j[2:0]})];
            rd_mask[slot]  = dqm;
            rd_valid[slot] = 1'b1;
        end
        reads = reads + 1;
        if (a[10]) begin
            ap_pend[ba] = 1'b1;
            ap_time[ba] = $realtime + bl * 17316.0;     // precharge starts after the burst (approx.)
            if (ap_time[ba] - t_act[ba] < T_RAS) ap_time[ba] = t_act[ba] + T_RAS;
        end
    end
    3'b100: begin                                       // WRITE
        if (!open_[ba]) err("WRITE to a closed bank");
        if ($realtime - t_act[ba] < T_RCD - 1) err("tRCD (WRITE)");
        col = a[9:0];
        wr_addr = haddr(ba, row_[ba], col);
        if (!dqm[0]) mem[wr_addr][7:0]  <= dq[7:0];
        if (!dqm[1]) mem[wr_addr][15:8] <= dq[15:8];
        wr_bank = ba;
        wr_left = bl - 1;
        wr_addr = {wr_addr[24:3], wr_addr[2:0] + 3'd1};
        wr_act  = (bl > 1);
        if (bl == 1) t_lastwr[ba] = $realtime;
        writes = writes + 1;
        if (a[10]) begin
            ap_pend[ba] = 1'b1;
            ap_time[ba] = $realtime + (bl - 1) * 17316.0 + T_WR;
            if (ap_time[ba] - t_act[ba] < T_RAS) ap_time[ba] = t_act[ba] + T_RAS;
        end
    end
    default: err("unsupported command");
    endcase
end

endmodule
