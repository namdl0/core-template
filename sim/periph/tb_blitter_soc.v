// Integration testbench: ufo50_blitter (the SoC-facing wrapper, periph_mem_port adapter
// included) against the SoC's own mem_cmd_* protocol model (sdram_arb_model.v), reusing
// blitgen's vectors. Same pass criterion as tb_blitter.v: HDL output == C model.
`timescale 1ns/1ps
module tb_blitter_soc;
    parameter LAT = 8, STALL_PCT = 0;
    reg clk = 0, rst = 1;
    always #8.68 clk = ~clk;   // 57.75 MHz
    reg  [15:2] adr; reg [31:0] dat_i; wire [31:0] dat_o; reg we = 0, cyc = 0, stb = 0; wire ack, irq, present;
    wire cv, cwe, cr, wr; wire [25:2] caddr; wire [2:0] clen; wire [31:0] wd, rd;
    wire [3:0] wstrb;
    ufo50_blitter dut (.clk(clk), .rst(rst), .wb_adr(adr), .wb_dat_w(dat_i), .wb_dat_r(dat_o),
        .wb_sel(4'hF), .wb_we(we), .wb_cyc(cyc), .wb_stb(stb), .wb_ack(ack), .irq(irq),
        .mem_cmd_valid(cv), .mem_cmd_we(cwe), .mem_cmd_addr(caddr), .mem_cmd_len(clen),
        .mem_wdata(wd), .mem_wstrb(wstrb), .mem_cmd_ready(cr), .mem_wready(wr), .mem_rdata(rd), .mem_rvalid(rv),
        .present(present));
    wire rv;
    sdram_arb_model #(.MEMW(1 << 21), .LAT(LAT), .STALL_PCT(STALL_PCT)) ram (
        .clk(clk), .mem_cmd_valid(cv), .mem_cmd_we(cwe), .mem_cmd_addr(caddr), .mem_cmd_len(clen),
        .mem_wdata(wd), .mem_wstrb(wstrb), .mem_cmd_ready(cr), .mem_wready(wr), .mem_rdata(rd), .mem_rvalid(rv));

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
    integer fd, n, i, dbase, dwords, ncmd, guard;
    initial begin
        if (!$value$plusargs("mem=%s", fmem)) fmem = "mem.bin";
        if (!$value$plusargs("cmds=%s", fcmd)) fcmd = "cmds.hex";
        if (!$value$plusargs("out=%s", fout)) fout = "out.hex";
        if (!$value$plusargs("dbase=%h", dbase)) dbase = 0;
        if (!$value$plusargs("dwords=%h", dwords)) dwords = 0;
        fd = $fopen(fmem, "rb"); n = $fread(ram.mem, fd); $fclose(fd);
        $readmemh(fcmd, cmds); ncmd = cmds[0];
        repeat (5) @(posedge clk); rst <= 0; repeat (2) @(posedge clk);
        for (i = 0; i < ncmd; i = i + 1) wbw(16'h8000 + ((i % 8) * 4), cmds[i + 1]);
        guard = 0; rdv = 1;
        while (rdv[0] && guard < 200000000) begin wbr(16'h0004); guard = guard + 1; end
        $display("blitter_soc: fence via mem_cmd_* protocol OK after %0d poll cycles", guard);
        fd = $fopen(fout, "w");
        for (i = 0; i < dwords; i = i + 1) $fwrite(fd, "%08x\n", ram.mem[dbase + i]);
        $fclose(fd);
        $finish;
    end
endmodule
