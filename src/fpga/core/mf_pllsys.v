//
// mf_pllsys.v - system clock PLL for the UFO50 Pocket SoC (M3)
//
// 74.25 MHz -> clk_sys. Hand-written altera_pll instance in the same form as the
// generated mf_pllbase_0002.v (the IP editor only fills these parameters in).
// Default 57.75 MHz = 74.25 x 14 / 18 (VCO 1039.5 MHz, integer N/M/C, no fractional
// mode). Exact alternatives with the same VCO (change OUT_FREQ and CLK_SYS_HZ in
// core_top.v together):
//   "51.975000 MHz" (C=20)   "49.500000 MHz" (C=21)   "64.968750 MHz" (C=16)
//
`timescale 1ns/10ps
module mf_pllsys #(
    parameter OUT_FREQ = "57.750000 MHz"
)(
    input  wire refclk,
    input  wire rst,
    output wire outclk_0,
    output wire locked
);
    altera_pll #(
        .fractional_vco_multiplier("false"),
        .reference_clock_frequency("74.25 MHz"),
        .operation_mode("normal"),
        .number_of_clocks(1),
        .output_clock_frequency0(OUT_FREQ),
        .phase_shift0("0 ps"),
        .duty_cycle0(50),
        .pll_type("General"),
        .pll_subtype("General")
    ) altera_pll_i (
        .rst      ( rst ),
        .outclk   ( outclk_0 ),
        .locked   ( locked ),
        .fboutclk ( ),
        .fbclk    ( 1'b0 ),
        .refclk   ( refclk )
    );
endmodule
