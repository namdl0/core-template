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
    parameter N = 6
)(
    input  wire              clk,
    input  wire              rst,

    input  wire [N-1:0]      p_valid,
    input  wire [N-1:0]      p_we,
    input  wire [N*24-1:0]   p_addr,      // [25:2] word address per port
    input  wire [N*3-1:0]    p_len,
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
    output wire [2:0]        c_len,
    output wire [31:0]       c_wdata,
    output wire [3:0]        c_wstrb,
    input  wire              c_wready,
    input  wire [31:0]       c_rdata,
    input  wire              c_rvalid
);

    reg         busy;
    reg  [2:0]  owner;
    reg         o_we;
    reg  [2:0]  left;

    // priority select (lowest index wins)
    reg  [2:0]  sel;
    reg         any;
    integer i;
    always @(*) begin
        sel = 3'd0;
        any = 1'b0;
        for (i = N-1; i >= 0; i = i - 1)
            if (p_valid[i]) begin
                sel = i[2:0];
                any = 1'b1;
            end
    end

    wire [2:0] m = busy ? owner : sel;

    assign c_valid = any && !busy;
    assign c_we    = p_we[sel];
    assign c_addr  = p_addr[sel*24 +: 24];
    assign c_len   = p_len[sel*3 +: 3];
    assign c_wdata = p_wdata[m*32 +: 32];
    assign c_wstrb = p_wstrb[m*4 +: 4];
    assign p_rdata = c_rdata;

    genvar g;
    generate for (g = 0; g < N; g = g + 1) begin : gp
        assign p_ready[g]  = c_ready && !busy && (sel == g);
        assign p_wready[g] = c_wready && busy && (owner == g);
        assign p_rvalid[g] = c_rvalid && busy && (owner == g);
    end endgenerate

always @(posedge clk) begin
    if (rst) begin
        busy <= 1'b0;
    end else if (!busy) begin
        if (c_valid && c_ready) begin
            busy  <= 1'b1;
            owner <= sel;
            o_we  <= c_we;
            left  <= c_len;
        end
    end else begin
        if ((o_we && c_wready) || (!o_we && c_rvalid)) begin
            if (left == 3'd0)
                busy <= 1'b0;
            else
                left <= left - 3'd1;
        end
    end
end

endmodule

`default_nettype wire
