//
// vl_top.v - Verilator wrapper for the UFO50 M3 SoC simulation (see tb_soc.cpp)
// ufo50_soc + ufo50_video (EXT=1); clocks, SDRAM pins and the APF side are driven from C++.
//
`default_nettype none
module vl_top (
    input  wire         clk_sys,
    input  wire         clk_mem,        // 2 x clk_sys, rising edges aligned (SDRAM controller, M5)
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
    input  wire         bridge_rd,
    output wire [31:0]  bridge_rd_data,
    output wire         t_read,
    output wire         t_write,
    output wire         t_flush,
    output wire [15:0]  t_id,
    output wire [31:0]  t_off,
    output wire [31:0]  t_baddr,
    output wire [31:0]  t_len,
    input  wire         t_ack,
    input  wire         t_done,
    input  wire [2:0]   t_err,
    output wire [9:0]   dt_addr,
    output wire         dt_wren,
    output wire [31:0]  dt_data,
    input  wire [31:0]  dt_q,
    input  wire [31:0]  cont1_key,

    output wire [23:0]  v_rgb,
    output wire         v_de,
    output wire         v_vs,
    output wire [1:0]   v_mode,
    output wire         dbg_wr,
    output wire [31:0]  dbg_val,
    output wire [31:0]  fb_active,
    output wire         fb_fmt32,
    output wire         dbg_dline,     // D$ line refill command accepted
    output wire         dbg_drsp_last, // last beat of a D$ response
    output wire         dbg_iline,
    output wire         dbg_irsp,
    output wire [15:0]  dbg_mem        // CPU memory events for the latency histograms (tb_soc.cpp)
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

    // 48 kHz audio_tick in clk_sys (on the Pocket, core_top derives it from the I2S LRCK):
    // 57.75 MHz / 48 kHz = 1203.125 cycles, as a fractional accumulator in 1/1024 cycles
    reg [20:0] aud_acc = 21'd0;
    reg        aud_tick = 1'b0;
    always @(posedge clk_sys) begin
        aud_tick <= 1'b0;
        if (aud_acc + 21'd1024 >= 21'd1232000) begin aud_acc <= aud_acc + 21'd1024 - 21'd1232000; aud_tick <= 1'b1; end
        else aud_acc <= aud_acc + 21'd1024;
    end

`ifdef SDRAM_1X
    localparam SD2X = 0;
`else
    localparam SD2X = 1;
`endif
    ufo50_soc #(.BOOT_HEX("sim/fw/boot"), .SDRAM_INIT_CYCLES(16'd200), .SDRAM_2X(SD2X)) soc (
        .clk_sys(clk_sys), .clk_mem(clk_mem), .rst_mem(rst_mem), .rst_sys(rst_sys),
        .sd_a(sd_a), .sd_ba(sd_ba), .sd_dqm(sd_dqm), .sd_cke(sd_cke), .sd_ras_n(sd_ras_n),
        .sd_cas_n(sd_cas_n), .sd_we_n(sd_we_n), .sd_dq_out(sd_dq_out), .sd_dq_oe(sd_dq_oe), .sd_dq_in(sd_dq_in),
        .clk_vid(clk_vid), .vid_x(hc), .vid_y(vc), .vid_fb_rgb(fb_rgb), .vid_mode(v_mode), .vid_border(border),
        .clk_74a(clk_74a), .bridge_addr(bridge_addr), .bridge_wr(bridge_wr), .bridge_wr_data(bridge_wr_data),
        .bridge_rd(bridge_rd), .bridge_rd_data(bridge_rd_data),
        .target_dataslot_read(t_read), .target_dataslot_write(t_write), .target_dataslot_flush(t_flush),
        .target_dataslot_id(t_id), .target_dataslot_slotoffset(t_off),
        .target_dataslot_bridgeaddr(t_baddr), .target_dataslot_length(t_len),
        .target_dataslot_ack(t_ack), .target_dataslot_done(t_done), .target_dataslot_err(t_err),
        .datatable_addr(dt_addr), .datatable_wren(dt_wren), .datatable_data(dt_data), .datatable_q(dt_q),
        .dataslot_allcomplete(1'b1), .osnotify_inmenu(1'b0), .rtc_epoch_seconds(32'd0), .rtc_valid(1'b0),
        .cont_key({96'd0, cont1_key}), .cont_joy(128'd0), .cont_trig(64'd0),
        .audio_tick(aud_tick), .audio_l(aud_l), .audio_r(aud_r)
    );

`ifdef BLITDBG
    // debug: every blitter SDRAM command touching blocks [BLITDBG_LO, BLITDBG_HI] (byte address >> 5),
    // its write beats, and the engine-side requests (sim/verilator: build with -DBLITDBG)
    localparam [20:0] DBG_LO = `BLITDBG_LO, DBG_HI = `BLITDBG_HI;
    reg dbg_on = 1'b0; reg [3:0] dbg_left = 4'd0; reg [63:0] dbg_cyc = 64'd0;
    wire [23:0] x0_addr = soc.p_addr[5*24 +: 24];
    always @(posedge clk_sys) begin
        dbg_cyc <= dbg_cyc + 1'b1;
        if (dbg_cyc >= `BLITDBG_C0 && dbg_cyc <= `BLITDBG_C1 && soc.arb.c_valid && soc.arb.c_ready)
            $display("%0d CTRL accept port %0d %s word %h len %0d", dbg_cyc, soc.arb.sel, soc.arb.c_we ? "WR" : "RD",
                     {soc.arb.c_addr, 2'b00}, soc.arb.c_len + 1);
        if (soc.p_valid[5] && soc.p_ready[5] && ((x0_addr[23:3] >= DBG_LO && x0_addr[23:3] <= DBG_HI)
            || (dbg_cyc >= `BLITDBG_C0 && dbg_cyc <= `BLITDBG_C1))) begin
            $display("%0d X0 %s word %h len %0d", dbg_cyc, soc.p_we[5] ? "WR" : "RD", {x0_addr, 2'b00}, soc.p_len[5*3 +: 3] + 1);
            if (soc.p_we[5]) begin dbg_on <= 1'b1; dbg_left <= {1'b0, soc.p_len[5*3 +: 3]} + 4'd1; end
        end
        if (dbg_on && soc.p_wready[5]) begin
            $display("%0d    beat %h strb %b", dbg_cyc, soc.p_wdata[5*32 +: 32], soc.p_wstrb[5*4 +: 4]);
            if (dbg_left == 4'd1) dbg_on <= 1'b0;
            dbg_left <= dbg_left - 1'b1;
        end
        if (dbg_cyc >= `BLITDBG_C0 && dbg_cyc <= `BLITDBG_C1) begin
            if (soc.blit.dut.eng.m_rvalid)
                $display("%0d   rvalid kind %0d slot %0d idx %0d data %h tot %0d", dbg_cyc, soc.blit.dut.eng.tq_head[22:20],
                         soc.blit.dut.eng.tq_head[19], soc.blit.dut.eng.rt_sum, soc.blit.dut.eng.m_rdata, soc.blit.dut.eng.returned_total);
            if (soc.blit.dut.eng.fs == 3'd6 && !soc.blit.dut.eng.job_valid)
                $display("%0d   F_W row %0d issued_total %0d returned %0d", dbg_cyc, soc.blit.dut.eng.f_row,
                         soc.blit.dut.eng.issued_total, soc.blit.dut.eng.returned_total);
            if (soc.blit.dut.eng.c_can)
                $display("%0d   compute start row %0d fd_row %0d returned %0d mark0 %0d mark1 %0d", dbg_cyc,
                         soc.blit.dut.eng.c_row, soc.blit.dut.eng.fd_row, soc.blit.dut.eng.returned_total,
                         soc.blit.dut.eng.mark[0], soc.blit.dut.eng.mark[1]);
        end
        if (soc.blit.dut.eng.m_valid && soc.blit.dut.eng.m_ready && soc.blit.dut.eng.m_addr[25:5] >= DBG_LO
            && soc.blit.dut.eng.m_addr[25:5] <= DBG_HI)
            $display("%0d ENG %s addr %h len %0d", dbg_cyc, soc.blit.dut.eng.m_write ? "WR" : "RD",
                     soc.blit.dut.eng.m_addr, soc.blit.dut.eng.m_len);
    end
`endif

    // firmware DEBUG_OUT (0x80000FFC) marker writes
    assign dbg_wr    = soc.m_cyc & soc.m_we & (soc.m_adr == 30'h2000_03FF) & soc.sys_ack;
    assign dbg_val   = soc.m_dat_w;
    assign fb_active = soc.fb_active;
    assign fb_fmt32  = soc.fmt_active;
    assign dbg_dline     = soc.dBus_cmd_valid & soc.dBus_cmd_ready & ~soc.dBus_cmd_payload_wr & (soc.dBus_cmd_payload_size == 3'd5);
    assign dbg_drsp_last = soc.dBus_rsp_valid & soc.dBus_rsp_payload_last;
    assign dbg_iline     = soc.iBus_cmd_valid & soc.iBus_cmd_ready;
    assign dbg_irsp      = soc.iBus_rsp_valid;
    assign dbg_mem = { soc.c_valid & soc.c_ready, soc.arb_owner, soc.arb_busy,
                       soc.p_ready[4], soc.p_valid[4], soc.p_ready[3], soc.p_valid[3],
                       soc.dBus_cmd_valid & soc.dBus_cmd_payload_wr, soc.dBus_rsp_valid & soc.dBus_rsp_payload_last,
                       soc.dBus_cmd_ready, soc.pc_d_line, soc.p_rvalid[4], soc.ib_state == 2'd2, soc.pc_i_go };
endmodule
`default_nettype wire
