#
# user core constraints
#
# put your clock groups in here as well as any net assignments
#

set_clock_groups -asynchronous \
 -group { bridge_spiclk } \
 -group { clk_74a } \
 -group { clk_74b } \
 -group { ic|mp1|mf_pllbase_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|mp1|mf_pllbase_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|mp1|mf_pllbase_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|mp1|mf_pllbase_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|mp2|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk }

# UFO50 M3 SDRAM interface. All SDRAM pins are driven/captured by IO-cell registers
# (FAST_*_REGISTER in ap_core.qsf) clocked by clk_sys, and dram_clk is ~clk_sys from a
# DDIO output, so the external timing is fixed by the IO cells: commands get ~P/2 setup
# and hold at the SDRAM, read data is captured on the falling edge in the middle of the
# CL=2 window (see soc/sdram_ctrl.v). No board delay model is available, so the pins
# are excluded from timing analysis instead of being left unconstrained.
set_false_path -to [get_ports {dram_a[*] dram_ba[*] dram_dqm[*] dram_dq[*] dram_ras_n dram_cas_n dram_we_n dram_cke dram_clk}]
set_false_path -from [get_ports {dram_dq[*]}]
