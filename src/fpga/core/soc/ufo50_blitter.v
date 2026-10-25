//
// ufo50_blitter.v - M3 STUB. The real blitter (branch ufo50-periph) replaces this file
// and must keep this module name and port list (docs/MEMORY_MAP.md sections 4-5).
// MMIO window 0x8002_0000; SDRAM master port X0 (lowest arbiter priority).
//
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
    output wire [2:0]  mem_cmd_len,
    output wire [31:0] mem_wdata,
    output wire [3:0]  mem_wstrb,
    input  wire        mem_cmd_ready,
    input  wire        mem_wready,
    input  wire [31:0] mem_rdata,
    input  wire        mem_rvalid,
    output wire        present         // 1 = real blitter (SYS_CONFIG bit 25)
);
    assign irq = 1'b0;
    assign present = 1'b0;
periph_stub #( .ID(32'h424C_4954) ) stub (     // "BLIT"
    .clk(clk), .rst(rst), .wb_adr(wb_adr), .wb_dat_w(wb_dat_w), .wb_sel(wb_sel), .wb_we(wb_we),
    .wb_cyc(wb_cyc), .wb_stb(wb_stb), .wb_dat_r(wb_dat_r), .wb_ack(wb_ack),
    .mem_cmd_valid(mem_cmd_valid), .mem_cmd_we(mem_cmd_we), .mem_cmd_addr(mem_cmd_addr),
    .mem_cmd_len(mem_cmd_len), .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
    .mem_cmd_ready(mem_cmd_ready), .mem_wready(mem_wready), .mem_rdata(mem_rdata), .mem_rvalid(mem_rvalid)
);
endmodule
`default_nettype wire
