// ufo50_mixer.v - replaces the M3 stub. Wraps periph/mixer.v to the exact port list
// docs/MEMORY_MAP.md sections 4-5 require: audio_tick/audio_l/audio_r instead of I2S pins
// (the SoC serialises to I2S itself). clk_74a and the I2S pins of periph/mixer.v are tied
// off; see that file's audio_tick path.
`default_nettype none
module ufo50_mixer (
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
    input  wire        audio_tick,
    output wire [15:0] audio_l,
    output wire [15:0] audio_r,
    output wire        present
);
    assign irq = 1'b0;     // the mixer core has no IRQ source yet (fence IRQ is a possible M4 addition)
    assign present = 1'b1;
    mixer dut (
        .clk(clk), .rst(rst), .clk_74a(1'b0),
        .wb_adr_i(wb_adr), .wb_dat_i(wb_dat_w), .wb_dat_o(wb_dat_r), .wb_sel_i(wb_sel),
        .wb_we_i(wb_we), .wb_cyc_i(wb_cyc), .wb_stb_i(wb_stb), .wb_ack_o(wb_ack),
        .mem_cmd_valid(mem_cmd_valid), .mem_cmd_we(mem_cmd_we), .mem_cmd_addr(mem_cmd_addr),
        .mem_cmd_len(mem_cmd_len), .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
        .mem_cmd_ready(mem_cmd_ready), .mem_wready(mem_wready), .mem_rdata(mem_rdata), .mem_rvalid(mem_rvalid),
        .audio_tick(audio_tick), .audio_l(audio_l), .audio_r(audio_r),
        .audio_mclk(), .audio_lrck(), .audio_dac()
    );
endmodule
`default_nettype wire
