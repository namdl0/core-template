//
// bridge_sdram.v - APF bridge writes -> SDRAM (UFO50 Pocket SoC, M3)
//
// Bridge writes to 0x1000_0000-0x13FF_FFFF (clk_74a) go through a 16-entry async
// FIFO into clk_sys, are gathered into an aligned 32-byte block (per-word strobes),
// and written with one 8-beat burst per block. A block is flushed when the next word
// falls outside it, when it is full, or after 16 idle clocks.
//
// The APF bridge is big-endian (bridge_endian_little = 0): byte 0 of the file is
// bridge_wr_data[31:24]. The CPU is little-endian, so each word is byte-swapped here
// and file byte n ends up at SDRAM byte n.
//
// There is no backpressure on the bridge. The FIFO drains at >= 1 word per ~3 clk_sys
// (bursts), far faster than the bridge can write.
//
`default_nettype none

module bridge_sdram (
    input  wire         clk_74a,
    input  wire [31:0]  bridge_addr,
    input  wire         bridge_wr,
    input  wire [31:0]  bridge_wr_data,

    input  wire         clk_sys,
    input  wire         rst_sys,
    output wire         p_valid,
    input  wire         p_ready,
    output wire [25:2]  p_addr,
    output wire [2:0]   p_len,
    output wire [31:0]  p_wdata,
    output wire [3:0]   p_wstrb,
    input  wire         p_wready,
    output wire         idle            // nothing buffered or in flight (sys domain)
);

// ------------------------------------------------------------- async FIFO
    localparam AW = 4;
    reg  [55:0] fmem [0:(1<<AW)-1];
    reg  [AW:0] wptr = 0, wptr_g = 0;
    reg  [AW:0] rptr;
    reg  [AW:0] wg_s1, wg_s2;          // wptr gray into sys

    function [AW:0] bin2gray(input [AW:0] b); bin2gray = b ^ (b >> 1); endfunction
    function [AW:0] gray2bin(input [AW:0] g);
        integer k;
        begin
            gray2bin[AW] = g[AW];
            for (k = AW-1; k >= 0; k = k - 1) gray2bin[k] = gray2bin[k+1] ^ g[k];
        end
    endfunction

    wire sel_sdram = (bridge_addr[31:26] == 6'b0001_00);    // 0x10000000-0x13FFFFFF
    wire [31:0] wd_le = {bridge_wr_data[7:0], bridge_wr_data[15:8], bridge_wr_data[23:16], bridge_wr_data[31:24]};

always @(posedge clk_74a) begin
    if (bridge_wr && sel_sdram) begin
        fmem[wptr[AW-1:0]] <= {bridge_addr[25:2], wd_le};
        wptr   <= wptr + 1'b1;
        wptr_g <= bin2gray(wptr + 1'b1);
    end
end

always @(posedge clk_sys) begin
    wg_s1 <= wptr_g;
    wg_s2 <= wg_s1;
end
    wire [AW:0] wptr_s = gray2bin(wg_s2);
    wire        f_empty = (wptr_s == rptr);
    wire [55:0] f_head  = fmem[rptr[AW-1:0]];

// ------------------------------------------------------ block gatherer
    reg [31:0] blk [0:7];
    reg [7:0]  blk_v;
    reg [25:5] blk_a;
    reg [3:0]  idle_cnt;
    reg        flushing;
    reg        issued;
    reg [2:0]  beat;

    wire [25:2] h_addr = f_head[55:32];
    wire        blk_any = |blk_v;
    wire        h_fits  = !blk_any || (h_addr[25:5] == blk_a);

    assign p_valid = flushing && !issued;
    assign p_addr  = {blk_a, 3'b000};
    assign p_len   = 3'd7;
    assign p_wdata = blk[beat];
    assign p_wstrb = {4{blk_v[beat]}};
    assign idle    = f_empty && !blk_any && !flushing;

always @(posedge clk_sys) begin
    if (rst_sys) begin
        rptr     <= 0;
        blk_v    <= 8'd0;
        flushing <= 1'b0;
        issued   <= 1'b0;
        beat     <= 3'd0;
        idle_cnt <= 4'd0;
    end else if (flushing) begin
        if (p_ready) issued <= 1'b1;
        if (p_wready) begin
            beat <= beat + 3'd1;
            if (beat == 3'd7) begin
                flushing <= 1'b0;
                issued   <= 1'b0;
                blk_v    <= 8'd0;
            end
        end
    end else if (!f_empty && h_fits) begin
        blk[h_addr[4:2]]   <= f_head[31:0];
        blk_v[h_addr[4:2]] <= 1'b1;
        blk_a              <= h_addr[25:5];
        rptr               <= rptr + 1'b1;
        idle_cnt           <= 4'd0;
        if ((blk_v | (8'd1 << h_addr[4:2])) == 8'hFF) begin
            flushing <= 1'b1;
            beat     <= 3'd0;
        end
    end else if (blk_any) begin
        // head is outside the block, or nothing arrived for a while
        idle_cnt <= idle_cnt + 4'd1;
        if (!f_empty || idle_cnt == 4'd15) begin
            flushing <= 1'b1;
            beat     <= 3'd0;
        end
    end
end

endmodule

`default_nettype wire
