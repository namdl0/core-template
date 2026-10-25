// End-to-end mixer test: Wishbone register writes -> mixer -> I2S pins. The TB decodes the
// I2S stream (SCLK = MCLK/4, as the DAC derives it) and compares it with the C model.
// Plusargs: +mem= +script= (all events at sample 0) +expect= +n=<samples to compare, hex>
`timescale 1ps/1ps
module tb_mixer_i2s;
    reg clk = 0, clk74 = 0, rst = 1;
    always #8730 clk = ~clk;      // 57.27 MHz
    always #6734 clk74 = ~clk74;  // 74.25 MHz
    reg [15:2] adr; reg [31:0] dat; reg we = 0, cyc = 0, stb = 0; wire ack; wire [31:0] dato;
    wire mv, mr, mrv, mw; wire [31:0] ma, mrd, mwd; wire [8:0] ml; wire [3:0] mbe;
    wire mclk, lrck, dac;
    mixer dut (.clk(clk), .rst(rst), .clk_74a(clk74), .wb_adr_i(adr), .wb_dat_i(dat), .wb_dat_o(dato), .wb_sel_i(4'hF),
        .wb_we_i(we), .wb_cyc_i(cyc), .wb_stb_i(stb), .wb_ack_o(ack),
        .mem_valid(mv), .mem_ready(mr), .mem_addr(ma), .mem_write(mw), .mem_len(ml), .mem_wdata(mwd), .mem_be(mbe),
        .mem_rdata(mrd), .mem_rvalid(mrv), .audio_mclk(mclk), .audio_lrck(lrck), .audio_dac(dac));
    sdram_model #(.MEMW(1 << 20), .LAT(12)) ram (.clk(clk), .p_valid(mv), .p_ready(mr), .p_addr(ma), .p_write(mw), .p_len(ml),
        .p_wdata(mwd), .p_be(mbe), .p_rdata(mrd), .p_rvalid(mrv));
    task wbw(input [15:0] a, input [31:0] d);
        begin
            @(posedge clk); adr <= a[15:2]; dat <= d; we <= 1; cyc <= 1; stb <= 1;
            @(posedge clk); while (!ack) @(posedge clk);
            cyc <= 0; stb <= 0; we <= 0;
        end
    endtask
    // I2S decoder
    wire sclk = dut.i2s.div[1];
    reg lr_d = 0; integer bitn = 0; reg [15:0] sh; reg [15:0] right; integer nf = 0;
    reg [31:0] got [0:4095];
    always @(posedge sclk) begin
        if (lrck != lr_d) bitn = 0; else bitn = bitn + 1;
        lr_d <= lrck;
        if (bitn >= 1 && bitn <= 16) sh = {sh[14:0], dac};
        if (bitn == 16) begin
            if (lrck) right = sh;
            else begin if (nf < 4096) got[nf] = {right, sh}; nf = nf + 1; end
        end
    end
    reg [31:0] scr [0:60000]; reg [31:0] exp_ [0:4095];
    reg [8*256-1:0] fmem, fscr, fexp;
    integer fd, n, i, N, off, ok, best;
    initial begin
        if (!$value$plusargs("mem=%s", fmem)) fmem = "mem.bin";
        if (!$value$plusargs("script=%s", fscr)) fscr = "script.hex";
        if (!$value$plusargs("expect=%s", fexp)) fexp = "expect.hex";
        if (!$value$plusargs("n=%h", N)) N = 200;
        fd = $fopen(fmem, "rb"); n = $fread(ram.mem, fd); $fclose(fd);
        $readmemh(fscr, scr); $readmemh(fexp, exp_);
        repeat (4) @(posedge clk); rst <= 0;
        wait (dut.core.s == 1);   // init done
        for (i = 0; i < scr[0]; i = i + 1) wbw({scr[2 + 3 * i][10:0], 2'b00}, scr[3 + 3 * i]);
        wbw(16'h0008, 1);
        wait (nf >= N + 40);
        best = -1;
        for (off = 0; off < 40 && best < 0; off = off + 1) begin
            ok = 1; for (i = 0; i < N; i = i + 1) if (got[off + i] !== exp_[i]) ok = 0;
            if (ok) best = off;
        end
        if (best >= 0) $display("mixer_i2s: PASS, %0d samples through I2S match the C model (latency %0d frames)", N, best);
        else begin
            $display("mixer_i2s: FAIL"); for (i = 0; i < 8; i = i + 1) $display("  got %h exp %h", got[i + 3], exp_[i]);
        end
        $finish;
    end
endmodule
