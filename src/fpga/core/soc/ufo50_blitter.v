// ufo50_blitter.v - replaces the M3 stub. Wraps periph/blitter.v to the exact port list
// docs/MEMORY_MAP.md sections 4-5 require (module name, port order, `present`).
`default_nettype none
module ufo50_blitter (
    input  wire        clk,
    input  wire        rst,
    input  wire [15:2] wb_adr,
    input  wire [31:0] wb_dat_w,
    input  wire [3:0]  wb_sel,
    input  wire        wb_we,
    input  wire        wb_cyc,
    input  wire        wb_stb,
    output wire [31:0] wb_dat_r,
    output wire        wb_ack,
    output wire        irq,
    output wire        mem_cmd_valid,
    output wire        mem_cmd_we,
    output wire [25:2] mem_cmd_addr,
    output wire [5:0]  mem_cmd_len,
    output wire [31:0] mem_wdata,
    output wire [3:0]  mem_wstrb,
    input  wire        mem_cmd_ready,
    input  wire        mem_wready,
    input  wire [31:0] mem_rdata,
    input  wire        mem_rvalid,
    output wire        present
);
    assign present = 1'b1;
    blitter dut (
        .clk(clk), .rst(rst),
        .wb_adr_i(wb_adr), .wb_dat_i(wb_dat_w), .wb_dat_o(wb_dat_r), .wb_sel_i(wb_sel),
        .wb_we_i(wb_we), .wb_cyc_i(wb_cyc), .wb_stb_i(wb_stb), .wb_ack_o(wb_ack), .irq(irq),
        .mem_cmd_valid(mem_cmd_valid), .mem_cmd_we(mem_cmd_we), .mem_cmd_addr(mem_cmd_addr),
        .mem_cmd_len(mem_cmd_len), .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
        .mem_cmd_ready(mem_cmd_ready), .mem_wready(mem_wready), .mem_rdata(mem_rdata), .mem_rvalid(mem_rvalid)
    );
endmodule
`default_nettype wire
