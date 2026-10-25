// Blitter testbench: loads a memory image, pushes a command stream through Wishbone,
// waits for the final FENCE and dumps a memory region as hex.
// Plusargs: +mem=<big-endian word image> +cmds=<hex words> +out=<hex> +dbase=<word idx hex> +dwords=<n hex>
`timescale 1ns/1ps
module tb_blitter;
    parameter LAT = 8, STALL_PCT = 0, GAP_PCT = 0, BEAT_CYC = 1, MAX_BURST = 64, MEMW = 1 << 21;
    reg clk = 0, rst = 1;
    always #8.77 clk = ~clk;   // ~57 MHz
    reg  [15:2] adr; reg [31:0] dat_i; wire [31:0] dat_o; reg we = 0, cyc = 0, stb = 0; wire ack, irq;
    wire mv, mr, mw, mrv; wire [31:0] ma, mwd, mrd; wire [8:0] ml; wire [3:0] mbe;
    blitter #(.MAX_BURST(MAX_BURST)) dut (.clk(clk), .rst(rst), .wb_adr_i(adr), .wb_dat_i(dat_i), .wb_dat_o(dat_o),
        .wb_sel_i(4'hF), .wb_we_i(we), .wb_cyc_i(cyc), .wb_stb_i(stb), .wb_ack_o(ack), .irq(irq),
        .mem_valid(mv), .mem_ready(mr), .mem_addr(ma), .mem_write(mw), .mem_len(ml), .mem_wdata(mwd), .mem_be(mbe),
        .mem_rdata(mrd), .mem_rvalid(mrv));
    sdram_model #(.MEMW(MEMW), .LAT(LAT), .STALL_PCT(STALL_PCT), .GAP_PCT(GAP_PCT), .BEAT_CYC(BEAT_CYC)) ram (
        .clk(clk), .p_valid(mv), .p_ready(mr), .p_addr(ma), .p_write(mw), .p_len(ml), .p_wdata(mwd), .p_be(mbe),
        .p_rdata(mrd), .p_rvalid(mrv));

    task wbw(input [15:0] a, input [31:0] d);
        begin
            @(posedge clk); adr <= a[15:2]; dat_i <= d; we <= 1; cyc <= 1; stb <= 1;
            @(posedge clk); while (!ack) @(posedge clk);
            cyc <= 0; stb <= 0; we <= 0;
        end
    endtask
    reg [31:0] rdv;
    task wbr(input [15:0] a);
        begin
            @(posedge clk); adr <= a[15:2]; we <= 0; cyc <= 1; stb <= 1;
            @(posedge clk); while (!ack) @(posedge clk);
            rdv = dat_o; cyc <= 0; stb <= 0;
        end
    endtask

    reg [31:0] cmds [0:1999999];
    reg [8*256-1:0] fmem, fcmd, fout;
    integer fd, n, i, dbase, dwords, ncmd, t0, t1, guard;
    integer cycles = 0;
    always @(posedge clk) cycles <= cycles + 1;
    integer trace = 0;
    initial if ($test$plusargs("trace")) trace = 1;
    always @(posedge clk) if (trace && cycles % 2000 == 0)
        $display("t=%0d ms=%0d fs=%0d ws=%0d ps=%0d rs=%0d op=%0d WxH=%0dx%0d f=%0d fd=%0d c=%0d comp=%0d w=%0d iss=%0d ret=%0d tq=%0d fifo=%0d",
            cycles, dut.eng.ms, dut.eng.fs, dut.eng.ws, dut.eng.ps, dut.eng.rs, dut.eng.op, dut.eng.W, dut.eng.H,
            dut.eng.f_row, dut.eng.fd_row, dut.eng.c_row, dut.eng.comp, dut.eng.w_row, dut.eng.issued_total, dut.eng.returned_total,
            dut.eng.tq_cnt, dut.cf_count);
    initial begin
        if (!$value$plusargs("mem=%s", fmem)) fmem = "mem.bin";
        if (!$value$plusargs("cmds=%s", fcmd)) fcmd = "cmds.hex";
        if (!$value$plusargs("out=%s", fout)) fout = "out.hex";
        if (!$value$plusargs("dbase=%h", dbase)) dbase = 0;
        if (!$value$plusargs("dwords=%h", dwords)) dwords = 0;
        fd = $fopen(fmem, "rb"); n = $fread(ram.mem, fd); $fclose(fd);
        $readmemh(fcmd, cmds);      // first word = number of command words
        ncmd = cmds[0];
        repeat (5) @(posedge clk); rst <= 0; repeat (2) @(posedge clk);
        t0 = cycles;
        for (i = 0; i < ncmd; i = i + 1) wbw(16'h8000 + ((i % 8) * 4), cmds[i + 1]);
        guard = 0;
        rdv = 1;
        while (rdv[0] && guard < 200000000) begin wbr(16'h0004); guard = guard + 1; end
        t1 = cycles;
        wbr(16'h0018); $display("blitter: %0d command words, %0d cycles, %0d pixels written", ncmd, t1 - t0, rdv);
        wbr(16'h0014); $display("blitter: busy cycles %0d", rdv);
        wbr(16'h001C); $display("blitter: memory wait cycles %0d", rdv);
        wbr(16'h000C); $display("blitter: fence %08x", rdv);
        fd = $fopen(fout, "w");
        for (i = 0; i < dwords; i = i + 1) $fwrite(fd, "%08x\n", ram.mem[dbase + i]);
        $fclose(fd);
        $finish;
    end
endmodule
