//
// vl_top.v - Verilator wrapper for the UFO50 M3 SoC simulation (see tb_soc.cpp)
// ufo50_soc + ufo50_video (EXT=1); clocks, SDRAM pins and the APF side are driven from C++.
//
`default_nettype none
module vl_top (
    input  wire         clk_sys,
    input  wire         clk_vid,
    input  wire         clk_74a,
    input  wire         rst_mem,
    input  wire         reset_n,

    output wire [12:0]  sd_a,
    output wire [1:0]   sd_ba,
    output wire [1:0]   sd_dqm,
    output wire         sd_cke,
    output wire         sd_ras_n,
    output wire         sd_cas_n,
    output wire         sd_we_n,
    output wire [15:0]  sd_dq_out,
    output wire         sd_dq_oe,
    input  wire [15:0]  sd_dq_in,

    input  wire [31:0]  bridge_addr,
    input  wire         bridge_wr,
    input  wire [31:0]  bridge_wr_data,
    output wire         t_read,
    output wire [15:0]  t_id,
    output wire [31:0]  t_off,
    output wire [31:0]  t_baddr,
    output wire [31:0]  t_len,
    input  wire         t_ack,
    input  wire         t_done,
    input  wire [2:0]   t_err,
    output wire [9:0]   dt_addr,
    input  wire [31:0]  dt_q,
    input  wire [31:0]  cont1_key,

    output wire [23:0]  v_rgb,
    output wire         v_de,
    output wire         v_vs,
    output wire [1:0]   v_mode,
    output wire         dbg_wr,
    output wire [31:0]  dbg_val,
    output wire [31:0]  fb_active,
    output wire         dbg_dline,     // D$ line refill command accepted
    output wire         dbg_drsp_last, // last beat of a D$ response
    output wire         dbg_iline,
    output wire         dbg_irsp
);
    reg rst_sys = 1'b1;
    always @(posedge clk_sys) rst_sys <= rst_mem | ~reset_n;

    wire [9:0]  hc, vc;
    wire [23:0] fb_rgb, border;
    wire        vhs, vskip;
    wire [15:0] vframe, aud_l, aud_r;

    ufo50_video #(.EXT(1)) vid (
        .clk(clk_vid), .reset_n(reset_n), .keys(16'h0),
        .rgb(v_rgb), .de(v_de), .hs(vhs), .vs(v_vs), .skip(vskip), .frame_count(vframe),
        .src_mode(v_mode), .fb_rgb(fb_rgb), .border_rgb(border), .hcount(hc), .vcount(vc)
    );

    ufo50_soc #(.BOOT_HEX("sim/fw/boot"), .SDRAM_INIT_CYCLES(16'd200)) soc (
        .clk_sys(clk_sys), .rst_mem(rst_mem), .rst_sys(rst_sys),
        .sd_a(sd_a), .sd_ba(sd_ba), .sd_dqm(sd_dqm), .sd_cke(sd_cke), .sd_ras_n(sd_ras_n),
        .sd_cas_n(sd_cas_n), .sd_we_n(sd_we_n), .sd_dq_out(sd_dq_out), .sd_dq_oe(sd_dq_oe), .sd_dq_in(sd_dq_in),
        .clk_vid(clk_vid), .vid_x(hc), .vid_y(vc), .vid_fb_rgb(fb_rgb), .vid_mode(v_mode), .vid_border(border),
        .clk_74a(clk_74a), .bridge_addr(bridge_addr), .bridge_wr(bridge_wr), .bridge_wr_data(bridge_wr_data),
        .target_dataslot_read(t_read), .target_dataslot_id(t_id), .target_dataslot_slotoffset(t_off),
        .target_dataslot_bridgeaddr(t_baddr), .target_dataslot_length(t_len),
        .target_dataslot_ack(t_ack), .target_dataslot_done(t_done), .target_dataslot_err(t_err),
        .datatable_addr(dt_addr), .datatable_q(dt_q),
        .dataslot_allcomplete(1'b1), .osnotify_inmenu(1'b0), .rtc_epoch_seconds(32'd0), .rtc_valid(1'b0),
        .cont_key({96'd0, cont1_key}), .cont_joy(128'd0), .cont_trig(64'd0),
        .audio_tick(1'b0), .audio_l(aud_l), .audio_r(aud_r)
    );

    // firmware DEBUG_OUT (0x80000FFC) marker writes
    assign dbg_wr    = soc.m_cyc & soc.m_we & (soc.m_adr == 30'h2000_03FF) & soc.sys_ack;
    assign dbg_val   = soc.m_dat_w;
    assign fb_active = soc.fb_active;
    assign dbg_dline     = soc.dBus_cmd_valid & soc.dBus_cmd_ready & ~soc.dBus_cmd_payload_wr & (soc.dBus_cmd_payload_size == 3'd5);
    assign dbg_drsp_last = soc.dBus_rsp_valid & soc.dBus_rsp_payload_last;
    assign dbg_iline     = soc.iBus_cmd_valid & soc.iBus_cmd_ready;
    assign dbg_irsp      = soc.iBus_rsp_valid;
endmodule
`default_nettype wire
