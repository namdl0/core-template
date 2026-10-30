//
// sdram_arb.v - fixed-priority arbiter in front of sdram_ctrl
//
// UFO50 Pocket SoC (M3). Every port uses the "SDRAM master port" protocol of
// docs/MEMORY_MAP.md section 5 (cmd valid/ready, pulled write beats, rvalid beats).
// Port 0 has the highest priority. Ports are flattened: port i uses bits
// [i*W +: W] of each bus.
//
`default_nettype none

module sdram_arb #(
    parameter N = 6,
    parameter PREEMPT = 1            // 1: the last port's (the blitter's) bursts yield to any waiting port
)(
    input  wire              clk,
    input  wire              rst,

    input  wire [N-1:0]      p_valid,
    input  wire [N-1:0]      p_we,
    input  wire [N*24-1:0]   p_addr,      // [25:2] word address per port
    input  wire [N*6-1:0]    p_len,       // beats - 1 (1..64, within one 2 KB SDRAM row)
    input  wire [N*32-1:0]   p_wdata,
    input  wire [N*4-1:0]    p_wstrb,
    output wire [N-1:0]      p_ready,
    output wire [N-1:0]      p_wready,
    output wire [N-1:0]      p_rvalid,
    output wire [31:0]       p_rdata,     // shared

    // to sdram_ctrl
    output wire              c_valid,
    input  wire              c_ready,
    output wire              c_we,
    output wire [25:2]       c_addr,
    output wire [5:0]        c_len,
    output wire [31:0]       c_wdata,
    output wire [3:0]        c_wstrb,
    input  wire              c_wready,
    input  wire [31:0]       c_rdata,
    input  wire              c_rvalid,
    output wire              c_stop,      // ask the controller to end the current burst early
    input  wire              c_cut,       // it does: this beat is the last of the access (comb.)
    input  wire [5:0]        c_cut_rem,   //   beats not done
    input  wire [25:2]       c_cut_addr,  //   where they continue

    // status (performance counters in ufo50_soc)
    output wire              busy_o,      // an access is in progress
    output wire [2:0]        owner_o      // its port
);

    reg         busy;
    reg  [2:0]  owner;
    reg         o_we;
    reg  [5:0]  left;

    // Preemption of the lowest-priority port (N-1, the blitter): when another port waits, the controller
    // ends the blitter's burst after a few beats (c_cut) and the rest is kept here as a continuation
    // (pend_*), issued again when port N-1 next wins arbitration. The master sees one command (one
    // p_ready), its beats in order, with a gap; nothing changes in the port protocol.
    reg         pend;
    reg  [25:2] pend_addr;
    reg  [5:0]  pend_len;
    reg         pend_we;
    wire [N-1:0] want = {pend | p_valid[N-1], p_valid[N-2:0]};

    // priority select (lowest index wins)
    reg  [2:0]  sel;
    reg         any;
    integer i;
    always @(*) begin
        sel = 3'd0;
        any = 1'b0;
        for (i = N-1; i >= 0; i = i - 1)
            if (want[i]) begin
                sel = i[2:0];
                any = 1'b1;
            end
    end
    wire        use_pend = pend && (sel == N-1);

    wire [2:0] m = busy ? owner : sel;
    assign busy_o  = busy;
    assign owner_o = owner;

    assign c_valid = any && !busy;
    assign c_we    = use_pend ? pend_we   : p_we[sel];
    assign c_addr  = use_pend ? pend_addr : p_addr[sel*24 +: 24];
    assign c_len   = use_pend ? pend_len  : p_len[sel*6 +: 6];
    assign c_wdata = p_wdata[m*32 +: 32];
    assign c_wstrb = p_wstrb[m*4 +: 4];
    assign p_rdata = c_rdata;
    assign c_stop  = PREEMPT && busy && (owner == N-1) && (|p_valid[N-2:0]);

    genvar g;
    generate for (g = 0; g < N; g = g + 1) begin : gp
        if (g == N-1)
            assign p_ready[g] = c_ready && !busy && (sel == g) && !pend;
        else
            assign p_ready[g] = c_ready && !busy && (sel == g);
        assign p_wready[g] = c_wready && busy && (owner == g);
        assign p_rvalid[g] = c_rvalid && busy && (owner == g);
    end endgenerate

    wire beat = (o_we && c_wready) || (!o_we && c_rvalid);
    wire cut  = PREEMPT && busy && c_cut;

always @(posedge clk) begin
    if (rst) begin
        busy <= 1'b0;
        pend <= 1'b0;
    end else if (!busy) begin
        if (c_valid && c_ready) begin
            busy  <= 1'b1;
            owner <= sel;
            o_we  <= c_we;
            left  <= c_len;
            if (use_pend) pend <= 1'b0;
        end
    end else begin
        if (cut) begin                       // the rest of this burst becomes the continuation
            pend      <= 1'b1;
            pend_addr <= c_cut_addr;
            pend_len  <= c_cut_rem - 6'd1;
            pend_we   <= o_we;
        end
        if (o_we && c_wready && cut)         // write: the cut beat is the access's last
            busy <= 1'b0;
        else if (beat) begin
            if (left == 6'd0)
                busy <= 1'b0;
            else
                left <= left - 6'd1 - (cut ? c_cut_rem : 6'd0);
        end else if (cut)
            left <= left - c_cut_rem;
    end
end

endmodule

`default_nettype wire
