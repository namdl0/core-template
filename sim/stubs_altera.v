//
// stubs_altera.v - simulation/lint stand-ins for the Intel IP used by the
// template (PLL, DDIO, dual-port RAM). Only used by sim/lint_core.sh so the
// whole apf_top -> core_top hierarchy can be elaborated with Icarus/Yosys.
// NOT part of the Quartus project.
//
`timescale 1ps/1ps

module mf_pllbase (
    input  wire refclk,
    input  wire rst,
    output reg  outclk_0 = 1'b0,
    output reg  outclk_1 = 1'b0,
    output wire outclk_2,
    output wire outclk_3,
    output wire outclk_4,
    output reg  locked = 1'b0
);
    // 12.288 MHz, outclk_1 lags by 90 degrees (20345 ps)
    // synthesis translate_off
    always #40690 outclk_0 = ~outclk_0;
    always @(outclk_0) outclk_1 <= #20345 outclk_0;
    initial #1000000 locked = 1'b1;
    // synthesis translate_on
    assign outclk_2 = 1'b0;
    assign outclk_3 = 1'b0;
    assign outclk_4 = 1'b0;
endmodule

module mf_ddio_bidir_12 (
    input  wire [11:0] datain_h,
    input  wire [11:0] datain_l,
    input  wire        inclock,
    input  wire        oe,
    input  wire        outclock,
    output wire [11:0] dataout_h,
    output wire [11:0] dataout_l,
    inout  wire [11:0] padio
);
    assign padio     = oe ? datain_h : 12'bz;
    assign dataout_h = padio;
    assign dataout_l = padio;
endmodule

module mf_datatable (
    input  wire [7:0]  address_a,
    input  wire [7:0]  address_b,
    input  wire        clock_a,
    input  wire        clock_b,
    input  wire [31:0] data_a,
    input  wire [31:0] data_b,
    input  wire        wren_a,
    input  wire        wren_b,
    output reg  [31:0] q_a,
    output reg  [31:0] q_b
);
    reg [31:0] mem [0:255];
    always @(posedge clock_a) begin
        if (wren_a) mem[address_a] <= data_a;
        q_a <= mem[address_a];
    end
    always @(posedge clock_b) begin
        if (wren_b) mem[address_b] <= data_b;
        q_b <= mem[address_b];
    end
endmodule
