// Mixer core testbench: replays a register-write schedule at exact sample indices and
// writes every output sample. Commands for sample k are queued before sample k-1 is
// accepted, so they apply exactly before sample k (as in the C model).
// Plusargs: +mem= +script= +out= +n=<samples, hex>
`timescale 1ns/1ps
module tb_mixer;
    parameter LAT = 12, STALL_PCT = 0, GAP_PCT = 0, BEAT_CYC = 1;
    reg clk = 0, rst = 1, en = 0;
    always #8.77 clk = ~clk;
    reg cf_wr = 0; reg [42:0] cf_wd; wire cf_rd, cf_empty, cf_full; wire [42:0] cf_data; wire [10:0] cf_count;
    periph_fifo #(.AW(10), .DW(43)) cf (.clk(clk), .rst(rst), .wr_en(cf_wr), .wr_data(cf_wd), .rd_en(cf_rd), .rd_data(cf_data),
        .empty(cf_empty), .full(cf_full), .count(cf_count));
    wire out_valid; reg out_ready = 0; wire [15:0] out_l, out_r; wire st_we; wire [5:0] st_wa; wire [31:0] st_wd, samples; wire [15:0] lastc;
    wire mv, mr, mrv; wire [31:0] ma, mrd; wire [8:0] ml;
    mix_core dut (.clk(clk), .rst(rst), .en(en), .cf_empty(cf_empty), .cf_rd(cf_rd), .cf_data(cf_data),
        .out_valid(out_valid), .out_ready(out_ready), .out_l(out_l), .out_r(out_r),
        .st_we(st_we), .st_wa(st_wa), .st_wd(st_wd), .samples(samples), .last_cycles(lastc),
        .m_valid(mv), .m_ready(mr), .m_addr(ma), .m_len(ml), .m_rdata(mrd), .m_rvalid(mrv));
    sdram_model #(.MEMW(1 << 20), .LAT(LAT), .STALL_PCT(STALL_PCT), .GAP_PCT(GAP_PCT), .BEAT_CYC(BEAT_CYC)) ram (
        .clk(clk), .p_valid(mv), .p_ready(mr), .p_addr(ma), .p_write(1'b0), .p_len(ml), .p_wdata(32'd0), .p_be(4'd0),
        .p_rdata(mrd), .p_rvalid(mrv));

    reg [31:0] scr [0:600000];
    reg [8*256-1:0] fmem, fscr, fout;
    integer fd, n, k, e, nev, N, maxc = 0; real sumc = 0;
    initial begin
        if (!$value$plusargs("mem=%s", fmem)) fmem = "mem.bin";
        if (!$value$plusargs("script=%s", fscr)) fscr = "script.hex";
        if (!$value$plusargs("out=%s", fout)) fout = "out.hex";
        if (!$value$plusargs("n=%h", N)) N = 100;
        fd = $fopen(fmem, "rb"); n = $fread(ram.mem, fd); $fclose(fd);
        $readmemh(fscr, scr); nev = scr[0]; e = 0;
        fd = $fopen(fout, "w");
        repeat (4) @(posedge clk); rst <= 0;
        for (k = 0; k < N; k = k + 1) begin
            while (e < nev && scr[1 + 3 * e] == k) begin
                @(posedge clk); while (cf_full) @(posedge clk);
                cf_wr <= 1; cf_wd <= {scr[2 + 3 * e][10:0], scr[3 + 3 * e]};
                @(posedge clk); cf_wr <= 0; e = e + 1;
            end
            if (k == 0) en <= 1;
            else begin out_ready <= 1; @(posedge clk); out_ready <= 0; end
            @(posedge clk); while (!out_valid) @(posedge clk);
            $fwrite(fd, "%04x%04x\n", out_r, out_l);
            if (lastc > maxc) maxc = lastc; sumc = sumc + lastc;
        end
        $fclose(fd);
        $display("mixer: %0d samples, cycles per sample avg %0d max %0d (budget at 57.27 MHz: 1193)", N, sumc / N, maxc);
        $finish;
    end
endmodule
