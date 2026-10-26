//
// bridge_sdram.v - APF bridge <-> SDRAM (UFO50 Pocket SoC, M3; reads added for saves)
//
// Writes: bridge writes to 0x1000_0000-0x13FF_FFFF (clk_74a) go through a 16-entry async
// FIFO into clk_sys, are gathered into an aligned 32-byte block (per-word strobes),
// and written with one 8-beat burst per block. A block is flushed when the next word
// falls outside it, when it is full, or after 16 idle clocks.
//
// Reads (data-slot write-back: target command 0x0184 and the APF's flush of nonvolatile
// slots on quit/sleep/power-off): a bridge read strobe for an SDRAM address is answered
// from two 32-byte block buffers (even/odd blocks). A hit is answered at once and the
// next block is prefetched, so a sequential read sequence never waits for the SDRAM after
// its first word; a miss fetches the block (one 8-beat burst, priority of port 1 in the
// arbiter) and answers when it arrives. The APF samples bridge_rd_data at its next read
// strobe (~microseconds later), which even a miss meets. The buffers are invalidated by
// every bridge write and by any SDRAM write command (any port) to the same 2 KB row, so
// the CPU rewriting a save region is always seen.
//
// The APF bridge is big-endian (bridge_endian_little = 0): byte 0 of the file is
// bridge_wr_data[31:24]. The CPU is little-endian, so each word is byte-swapped here
// and file byte n ends up at SDRAM byte n (and back again on reads).
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
    input  wire         bridge_rd,
    output reg  [31:0]  bridge_rd_data,     // valid from ~20 clk_74a after the strobe (hit) until the next answer

    input  wire         clk_sys,
    input  wire         rst_sys,
    output wire         p_valid,
    input  wire         p_ready,
    output wire         p_we,
    output wire [25:2]  p_addr,
    output wire [5:0]   p_len,
    output wire [31:0]  p_wdata,
    output wire [3:0]   p_wstrb,
    input  wire         p_wready,
    input  wire [31:0]  p_rdata,
    input  wire         p_rvalid,
    // snoop of the arbiter's accepted commands (read-buffer invalidation)
    input  wire         snoop_we,           // c_valid & c_ready & c_we
    input  wire [25:2]  snoop_addr,
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
    function [31:0] bswap(input [31:0] w); bswap = {w[7:0], w[15:8], w[23:16], w[31:24]}; endfunction

    wire sel_sdram = (bridge_addr[31:26] == 6'b0001_00);    // 0x10000000-0x13FFFFFF
    wire [31:0] wd_le = bswap(bridge_wr_data);

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

// ------------------------------------------------------ read requests (74a -> sys)
    reg         rd_prev_74 = 1'b0;
    reg         rq_t_74 = 1'b0;         // toggles per request
    reg  [25:2] rq_addr_74;
    reg         wr_t_74 = 1'b0;         // toggles per bridge write to SDRAM (invalidation)
    reg         rsp_t_sys = 1'b0;       // toggles per answer (sys -> 74a)
    reg  [31:0] rsp_data_sys;
    reg  [2:0]  rsp_s_74;

always @(posedge clk_74a) begin
    rd_prev_74 <= bridge_rd;
    if (bridge_rd && !rd_prev_74 && sel_sdram) begin
        rq_addr_74 <= bridge_addr[25:2];
        rq_t_74    <= ~rq_t_74;
    end
    if (bridge_wr && sel_sdram) wr_t_74 <= ~wr_t_74;
    rsp_s_74 <= {rsp_s_74[1:0], rsp_t_sys};
    if (rsp_s_74[2] ^ rsp_s_74[1]) bridge_rd_data <= bswap(rsp_data_sys);   // stable since the toggle
end

// ------------------------------------------------------ block gatherer (writes)
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

// ------------------------------------------------------ read buffers (sys)
    reg [31:0] rb0 [0:7];
    reg [31:0] rb1 [0:7];
    reg        rb_valid [0:1];
    reg [25:5] rb_blk [0:1];
    reg        rd_busy;                 // a fetch burst is in flight (command issued or waiting)
    reg        rd_issued;
    reg        rd_stale;                // a write to the fetched row was accepted during the fetch
    reg        rd_buf;                  // buffer being filled
    reg [25:5] rd_blk;
    reg [2:0]  rd_beat;
    reg        rq_pend;                 // a request waits for data
    reg [25:2] rq_addr;
    reg        pf_pend;                 // prefetch wanted
    reg [25:5] pf_blk;
    reg [2:0]  rq_s, wr_s;

    wire [25:5] rq_blk  = rq_addr[25:5];
    wire        rq_bsel = rq_addr[5];
    wire        rq_hit  = rb_valid[rq_bsel] && rb_blk[rq_bsel] == rq_blk;
    wire        pf_have = rb_valid[pf_blk[5]] && rb_blk[pf_blk[5]] == pf_blk;
    wire [31:0] hit_word = rq_bsel ? rb1[rq_addr[4:2]] : rb0[rq_addr[4:2]];

    assign p_valid = (flushing && !issued) || (rd_busy && !rd_issued);
    assign p_we    = flushing;
    assign p_addr  = flushing ? {blk_a, 3'b000} : {rd_blk, 3'b000};
    assign p_len   = 6'd7;
    assign p_wdata = blk[beat];
    assign p_wstrb = {4{blk_v[beat]}};
    assign idle    = f_empty && !blk_any && !flushing && !rd_busy && !rq_pend;

    // a write burst starts this cycle (the read engine then waits: one command per port)
    wire wr_take  = !flushing && !f_empty && h_fits && blk_v != 8'hFF;
    wire wr_start = !rd_busy && !flushing &&
                    ((wr_take && ((blk_v | (8'd1 << h_addr[4:2])) == 8'hFF)) ||
                     (!wr_take && blk_any && (!f_empty || idle_cnt == 4'd15)));

    integer k;
    initial begin
        rb_valid[0] = 1'b0; rb_valid[1] = 1'b0;
        for (k = 0; k < 8; k = k + 1) begin rb0[k] = 32'd0; rb1[k] = 32'd0; end
    end

always @(posedge clk_sys) begin
    rq_s <= {rq_s[1:0], rq_t_74};
    wr_s <= {wr_s[1:0], wr_t_74};
    if (rst_sys) begin
        rptr     <= 0;
        blk_v    <= 8'd0;
        flushing <= 1'b0;
        issued   <= 1'b0;
        beat     <= 3'd0;
        idle_cnt <= 4'd0;
        rd_busy  <= 1'b0;
        rd_issued<= 1'b0;
        rd_stale <= 1'b0;
        rq_pend  <= 1'b0;
        pf_pend  <= 1'b0;
        rb_valid[0] <= 1'b0;
        rb_valid[1] <= 1'b0;
    end else begin
        // ---------------- writes
        if (flushing) begin
            if (p_ready) issued <= 1'b1;
            if (p_wready) begin
                beat <= beat + 3'd1;
                if (beat == 3'd7) begin
                    flushing <= 1'b0;
                    issued   <= 1'b0;
                    blk_v    <= 8'd0;
                end
            end
        end else if (wr_take) begin
            blk[h_addr[4:2]]   <= f_head[31:0];
            blk_v[h_addr[4:2]] <= 1'b1;
            blk_a              <= h_addr[25:5];
            rptr               <= rptr + 1'b1;
            idle_cnt           <= 4'd0;
        end else if (blk_any && !rd_busy) begin
            // head is outside the block, or nothing arrived for a while
            idle_cnt <= idle_cnt + 4'd1;
        end
        if (wr_start) begin
            flushing <= 1'b1;
            beat     <= 3'd0;
        end

        // ---------------- read buffer invalidation (bridge writes, any SDRAM write to the row)
        if (wr_s[2] ^ wr_s[1]) begin rb_valid[0] <= 1'b0; rb_valid[1] <= 1'b0; end
        if (snoop_we) begin
            if (rb_blk[0][25:11] == snoop_addr[25:11]) rb_valid[0] <= 1'b0;
            if (rb_blk[1][25:11] == snoop_addr[25:11]) rb_valid[1] <= 1'b0;
        end
        if (snoop_we && rd_blk[25:11] == snoop_addr[25:11]) rd_stale <= 1'b1;

        // ---------------- read requests
        if (rq_s[2] ^ rq_s[1]) begin
            rq_pend <= 1'b1;
            rq_addr <= rq_addr_74;          // stable since the toggle
        end
        if (rq_pend && rq_hit && !(rq_s[2] ^ rq_s[1])) begin   // (a newer request supersedes an unanswered one)
            rsp_data_sys <= hit_word;
            rsp_t_sys    <= ~rsp_t_sys;
            rq_pend      <= 1'b0;
            pf_blk       <= rq_blk + 21'd1;
            pf_pend      <= (rq_blk != 21'h1FFFFF);
        end

        // ---------------- fetch engine
        if (rd_busy) begin
            if (p_ready && !flushing) rd_issued <= 1'b1;
            if (p_rvalid) begin
                if (rd_buf) rb1[rd_beat] <= p_rdata; else rb0[rd_beat] <= p_rdata;
                rd_beat <= rd_beat + 3'd1;
                if (rd_beat == 3'd7) begin
                    rd_busy   <= 1'b0;
                    rd_issued <= 1'b0;
                    // not valid if a write to the row was accepted after this read command
                    rb_valid[rd_buf] <= !(rd_stale || (snoop_we && rd_blk[25:11] == snoop_addr[25:11]));
                    rb_blk[rd_buf]   <= rd_blk;
                end
            end
        end else if (!flushing && !wr_start) begin
            if (rq_pend && !rq_hit) begin
                rd_busy <= 1'b1; rd_issued <= 1'b0; rd_beat <= 3'd0; rd_stale <= 1'b0;
                rd_buf  <= rq_blk[5]; rd_blk <= rq_blk;
                rb_valid[rq_blk[5]] <= 1'b0;
            end else if (pf_pend) begin
                pf_pend <= 1'b0;
                if (!pf_have) begin
                    rd_busy <= 1'b1; rd_issued <= 1'b0; rd_beat <= 3'd0; rd_stale <= 1'b0;
                    rd_buf  <= pf_blk[5]; rd_blk <= pf_blk;
                    rb_valid[pf_blk[5]] <= 1'b0;
                end
            end
        end
    end
end

endmodule

`default_nettype wire
