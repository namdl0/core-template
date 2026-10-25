//
// tb_soc.v - UFO50 M3 SoC testbench (Icarus Verilog 12)
//
// ufo50_soc + generated VexRiscv + sdram_model + ufo50_video, running the -DSIM build
// of firmware/hello (sim/fw/boot_b*.hex). It emulates the APF side:
//   - loads a 256-byte "slot 0" over the bridge to 0x10000000 while reset_n is low,
//   - provides the data-slot size table (datatable),
//   - answers target command 0x0180 (data slot read) with bridge writes.
// It follows the firmware through DEBUG_OUT (0x80000FFC) markers, captures video frames
// (sim/out/frame_N.ppm) and compares each frame of the live loop with the framebuffer
// contents in the SDRAM model. Pass = trap-free run, all markers, 0 SDRAM model errors,
// 0 pixel mismatches.
//
`timescale 1ps/1ps
`default_nettype none

module tb_soc;
    parameter real TCO   = 4000.0;     // FPGA output delay to the SDRAM pins (ps), incl. dram_clk
    parameter real BOARD = 500.0;      // SDRAM -> FPGA input delay (ps)
    parameter      MAX_MS = 120;       // simulated time limit

    // ---------------------------------------------------------------- clocks
    reg clk_sys = 0, clk_vid = 0, clk_74a = 0;
    always #8658 clk_sys = ~clk_sys;        // 57.75 MHz
    always #40690 clk_vid = ~clk_vid;       // 12.288 MHz
    always #6734 clk_74a = ~clk_74a;        // 74.25 MHz

    reg rst_mem = 1, reset_n = 0;
    reg rst_sys = 1;
    always @(posedge clk_sys) rst_sys <= rst_mem | ~reset_n;

    // ---------------------------------------------------------------- SDRAM
    wire [12:0] sd_a;   wire [1:0] sd_ba, sd_dqm;
    wire sd_cke, sd_ras_n, sd_cas_n, sd_we_n, sd_dq_oe;
    wire [15:0] sd_dq_out;
    wire [12:0] p_a;    wire [1:0] p_ba, p_dqm;
    wire p_cke, p_ras_n, p_cas_n, p_we_n, p_oe, p_clk;
    wire [15:0] p_dq_out;
    assign #(TCO) p_a = sd_a;
    assign #(TCO) p_ba = sd_ba;
    assign #(TCO) p_dqm = sd_dqm;
    assign #(TCO) p_cke = sd_cke;
    assign #(TCO) p_ras_n = sd_ras_n;
    assign #(TCO) p_cas_n = sd_cas_n;
    assign #(TCO) p_we_n = sd_we_n;
    assign #(TCO) p_oe = sd_dq_oe;
    assign #(TCO) p_dq_out = sd_dq_out;
    assign #(TCO) p_clk = ~clk_sys;           // DDIO: inverted clk_sys, same IO delay
    wire [15:0] dq = p_oe ? p_dq_out : 16'hzzzz;
    wire [15:0] dq_in;
    assign #(BOARD) dq_in = dq;

    sdram_model mem (.clk(p_clk), .cke(p_cke), .ras_n(p_ras_n), .cas_n(p_cas_n), .we_n(p_we_n),
                     .ba(p_ba), .a(p_a), .dqm(p_dqm), .dq(dq));

    // ---------------------------------------------------------------- video timing
    wire [9:0] hc, vc;
    wire [23:0] fb_rgb, vrgb, border;
    wire [1:0] vmode;
    wire vde, vhs, vvs, vskip;
    wire [15:0] vframe;
    ufo50_video #(.EXT(1)) vid (
        .clk(clk_vid), .reset_n(reset_n), .keys(16'h0),
        .rgb(vrgb), .de(vde), .hs(vhs), .vs(vvs), .skip(vskip), .frame_count(vframe),
        .src_mode(vmode), .fb_rgb(fb_rgb), .border_rgb(border), .hcount(hc), .vcount(vc)
    );

    // ---------------------------------------------------------------- APF emulation
    reg  [31:0] bridge_addr = 0, bridge_wr_data = 0;
    reg         bridge_wr = 0;
    wire        t_read;
    wire [15:0] t_id;
    wire [31:0] t_off, t_baddr, t_len;
    reg         t_ack = 0, t_done = 0;
    reg  [2:0]  t_err = 0;
    wire [9:0]  dt_addr;
    reg  [31:0] dt_q = 0, dt_q1 = 0;
    reg  [9:0]  dt_addr_r = 0;

    localparam SLOT0_SIZE = 256;
    reg [7:0] slot0 [0:SLOT0_SIZE-1];
    integer k;
    initial for (k = 0; k < SLOT0_SIZE; k = k + 1) slot0[k] = (k * 37 + 11) ^ (k >> 3);

    // datatable: entry 0 = {id 0, 256 bytes}; registered address and output (2 clocks)
    always @(posedge clk_74a) begin
        dt_addr_r <= dt_addr;
        dt_q1 <= (dt_addr_r == 10'd1) ? SLOT0_SIZE : 32'd0;
        dt_q  <= dt_q1;
    end

    task bridge_write(input [31:0] addr, input [31:0] data);
        begin
            @(posedge clk_74a);
            bridge_addr <= addr; bridge_wr_data <= data; bridge_wr <= 1'b1;
            @(posedge clk_74a);
            bridge_wr <= 1'b0;
            repeat (6) @(posedge clk_74a);
        end
    endtask

    // big-endian bridge word of slot bytes [o..o+3]
    function [31:0] slot_word(input integer o);
        slot_word = {slot0[o], slot0[o+1], slot0[o+2], slot0[o+3]};
    endfunction

    // target command 0x0180
    integer n_0180 = 0;
    always @(posedge t_read) begin
        n_0180 = n_0180 + 1;
        repeat (4) @(posedge clk_74a);
        t_done <= 1'b0;
        repeat (30) @(posedge clk_74a);
        t_ack <= 1'b1;
        for (k = 0; k < t_len; k = k + 4)
            bridge_write(t_baddr + k, (t_id == 0 && t_off + k + 3 < SLOT0_SIZE) ? slot_word(t_off + k) : 32'hFFFFFFFF);
        t_ack <= 1'b0;
        t_err <= (t_id == 0) ? 3'd0 : 3'd2;
        t_done <= 1'b1;
        $display("[%0t ns] APF: 0x0180 slot %0d off %0d -> %h len %0d", $time/1000, t_id, t_off, t_baddr, t_len);
    end

    // ---------------------------------------------------------------- DUT
    wire [15:0] aud_l, aud_r;
    ufo50_soc #(.BOOT_HEX("sim/fw/boot"), .SDRAM_INIT_CYCLES(16'd200)) soc (
        .clk_sys(clk_sys), .rst_mem(rst_mem), .rst_sys(rst_sys),
        .sd_a(sd_a), .sd_ba(sd_ba), .sd_dqm(sd_dqm), .sd_cke(sd_cke), .sd_ras_n(sd_ras_n),
        .sd_cas_n(sd_cas_n), .sd_we_n(sd_we_n), .sd_dq_out(sd_dq_out), .sd_dq_oe(sd_dq_oe), .sd_dq_in(dq_in),
        .clk_vid(clk_vid), .vid_x(hc), .vid_y(vc), .vid_fb_rgb(fb_rgb), .vid_mode(vmode), .vid_border(border),
        .clk_74a(clk_74a), .bridge_addr(bridge_addr), .bridge_wr(bridge_wr), .bridge_wr_data(bridge_wr_data),
        .target_dataslot_read(t_read), .target_dataslot_id(t_id), .target_dataslot_slotoffset(t_off),
        .target_dataslot_bridgeaddr(t_baddr), .target_dataslot_length(t_len),
        .target_dataslot_ack(t_ack), .target_dataslot_done(t_done), .target_dataslot_err(t_err),
        .datatable_addr(dt_addr), .datatable_q(dt_q),
        .dataslot_allcomplete(1'b1), .osnotify_inmenu(1'b0), .rtc_epoch_seconds(32'd0), .rtc_valid(1'b0),
        .cont_key({96'd0, 32'h0000_0011}), .cont_joy(128'd0), .cont_trig(64'd0),
        .audio_tick(1'b0), .audio_l(aud_l), .audio_r(aud_r)
    );

    // ---------------------------------------------------------------- firmware markers
    reg [31:0] marker = 0;
    integer    live_frames = 0;
    always @(posedge clk_sys)
        if (soc.m_cyc && soc.m_we && soc.m_adr == 30'h2000_03FF && soc.sys_ack) begin
            marker = soc.m_dat_w;
            if (marker[31:16] == 16'hDEAD) begin
                $display("[%0t ns] FIRMWARE TRAP mcause=%h", $time/1000, marker[15:0]);
                finish_sim(1);
            end else if (marker[31:16] == 16'h0001) begin
                live_frames = marker[15:0];
            end else
                $display("[%0t ns] firmware step %0d", $time/1000, marker);
        end

    // ---------------------------------------------------------------- frame capture + compare
    reg [23:0] cap [0:384*216-1];
    integer cx = 0, cy = 0, frame_no = 0, cmp_frames = 0, mismatches = 0, captured = 0;
    reg [31:0] fb_at_start;
    reg frame_valid = 0, cmp_this = 0;
    integer fd, x, y, a;
    reg [15:0] px;
    reg [23:0] exp;

    always @(posedge clk_vid) begin
        if (vvs) begin
            if (frame_valid && captured == 384*216) begin
                // write the frame and compare with SDRAM contents of the buffer that was shown
                fd = $fopen($sformatf("sim/out/frame_%02d.ppm", frame_no), "w");
                $fwrite(fd, "P3\n384 216\n255\n");
                for (a = 0; a < 384*216; a = a + 1)
                    $fwrite(fd, "%0d %0d %0d\n", cap[a][23:16], cap[a][15:8], cap[a][7:0]);
                $fclose(fd);
                if (cmp_this) begin
                    cmp_frames = cmp_frames + 1;
                    for (a = 0; a < 384*216; a = a + 1) begin
                        px  = mem.mem[(fb_at_start[25:0] >> 1) + a];
                        exp = {px[15:11], px[15:13], px[10:5], px[10:9], px[4:0], px[4:2]};
                        if (exp !== cap[a]) begin
                            if (mismatches < 10) $display("pixel mismatch frame %0d (%0d,%0d): got %h want %h",
                                                          frame_no, a % 384, a / 384, cap[a], exp);
                            mismatches = mismatches + 1;
                        end
                    end
                    $display("[%0t ns] frame %0d compared with SDRAM buffer %h: %0d mismatches so far",
                             $time/1000, frame_no, fb_at_start, mismatches);
                end else
                    $display("[%0t ns] frame %0d captured (mode %0d)", $time/1000, frame_no, vmode);
                frame_no = frame_no + 1;
                if (live_frames >= 3 && cmp_frames >= 2) finish_sim(0);
            end
            frame_valid = (vmode == 2'd1);
            captured = 0;
        end
        if (vde) begin
            if (captured == 0) begin fb_at_start = soc.fb_active; cmp_this = (marker == 32'd7) || (live_frames > 0); end
            cap[captured] = vrgb;
            captured = captured + 1;
        end
    end

    // ---------------------------------------------------------------- sequence
    task finish_sim(input integer trapped);
        begin
            $display("---------------------------------------------------------------");
            $display("SDRAM model: %0d errors, %0d reads, %0d writes, %0d refreshes",
                     mem.errors, mem.reads, mem.writes, mem.refreshes);
            $display("frames compared %0d, pixel mismatches %0d, live frames %0d, 0x0180 commands %0d",
                     cmp_frames, mismatches, live_frames, n_0180);
            if (!trapped && mem.errors == 0 && mismatches == 0 && cmp_frames >= 2 && live_frames >= 3 && n_0180 >= 1)
                $display("TB_SOC PASS");
            else
                $display("TB_SOC FAIL");
            $finish;
        end
    endtask

    initial begin
        #1000000;               // 1 us: PLL lock
        rst_mem = 0;
        #20000000;              // SDRAM init (200 clocks + refreshes)
        $display("[%0t ns] APF: loading slot 0 (%0d bytes) over the bridge", $time/1000, SLOT0_SIZE);
        for (k = 0; k < SLOT0_SIZE; k = k + 4) bridge_write(32'h1000_0000 + k, slot_word(k));
        #2000000;
        reset_n = 1;
        $display("[%0t ns] APF: reset_n released", $time/1000);
    end

    initial begin
        #(MAX_MS * 64'd1000000000);
        $display("TIMEOUT at marker %h", marker);
        finish_sim(1);
    end

    // simple progress: CPU PC every 2 ms
    always begin
        #2000000000;
        $display("[%0t ns] ... marker %h, video frame %0d", $time/1000, marker, vframe);
    end
endmodule

`default_nettype wire
