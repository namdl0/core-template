// Integration testbench: ufo50_mixer (audio_tick path + periph_mem_port adapter) driven
// over Wishbone, against the SoC's mem_cmd_* memory model, with audio_tick pulsed once per
// sample. Reuses mixgen's vectors/expect.hex (same pass criterion as tb_mixer.v).
`timescale 1ns/1ps
module tb_mixer_tick;
    parameter LAT = 12, STALL_PCT = 0;
    reg clk = 0, rst = 1;
    always #8.68 clk = ~clk;   // 57.75 MHz
    reg  [15:2] adr; reg [31:0] dat_i; wire [31:0] dat_o; reg we = 0, cyc = 0, stb = 0; wire ack, irq, present;
    reg tick = 0; wire [15:0] al, ar;
    wire cv, cwe, rvv, wr; wire [25:2] caddr; wire [2:0] clen; wire [31:0] wd, rdt;
    wire [3:0] wstrb;
    ufo50_mixer dut (.clk(clk), .rst(rst), .wb_adr(adr), .wb_dat_w(dat_i), .wb_dat_r(dat_o), .wb_sel(4'hF),
        .wb_we(we), .wb_cyc(cyc), .wb_stb(stb), .wb_ack(ack), .irq(irq),
        .mem_cmd_valid(cv), .mem_cmd_we(cwe), .mem_cmd_addr(caddr), .mem_cmd_len(clen),
        .mem_wdata(wd), .mem_wstrb(wstrb), .mem_cmd_ready(cr), .mem_wready(wr), .mem_rdata(rdt), .mem_rvalid(rvv),
        .audio_tick(tick), .audio_l(al), .audio_r(ar), .present(present));
    wire cr;
    sdram_arb_model #(.MEMW(1 << 20), .LAT(LAT), .STALL_PCT(STALL_PCT)) ram (
        .clk(clk), .mem_cmd_valid(cv), .mem_cmd_we(cwe), .mem_cmd_addr(caddr), .mem_cmd_len(clen),
        .mem_wdata(wd), .mem_wstrb(wstrb), .mem_cmd_ready(cr), .mem_wready(wr), .mem_rdata(rdt), .mem_rvalid(rvv));

    task wbw(input [15:0] a, input [31:0] d);
        begin
            @(posedge clk); adr <= a[15:2]; dat_i <= d; we <= 1; cyc <= 1; stb <= 1;
            @(posedge clk); while (!ack) @(posedge clk);
            cyc <= 0; stb <= 0; we <= 0;
        end
    endtask
    reg [31:0] scr [0:600000];
    reg [8*256-1:0] fmem, fscr, fout;
    integer fd, n, k, e, nev, N;
    initial begin
        if (!$value$plusargs("mem=%s", fmem)) fmem = "mem.bin";
        if (!$value$plusargs("script=%s", fscr)) fscr = "script.hex";
        if (!$value$plusargs("out=%s", fout)) fout = "out.hex";
        if (!$value$plusargs("n=%h", N)) N = 100;
        fd = $fopen(fmem, "rb"); n = $fread(ram.mem, fd); $fclose(fd);
        $readmemh(fscr, scr); nev = scr[0]; e = 0;
        fd = $fopen(fout, "w");
        repeat (4) @(posedge clk); rst <= 0;
        wait (dut.dut.core.s == 1);   // mix_core init done
        wbw(16'h0008, 1);             // enable
        for (k = 0; k < N; k = k + 1) begin
            while (e < nev && scr[1 + 3 * e] == k) begin
                wbw({scr[2 + 3 * e][10:0], 2'b00}, scr[3 + 3 * e]); e = e + 1;
            end
            repeat (1203) @(posedge clk);   // real hardware's 48 kHz tick spacing at 57.75 MHz
            @(posedge clk); tick <= 1; @(posedge clk); tick <= 0;
            repeat (2) @(posedge clk);      // let the pop settle (1-cycle FIFO read latency)
            $fwrite(fd, "%04x%04x\n", ar, al);
        end
        $fclose(fd);
        $display("mixer_tick: %0d samples via mem_cmd_* + audio_tick", N);
        $finish;
    end
endmodule
