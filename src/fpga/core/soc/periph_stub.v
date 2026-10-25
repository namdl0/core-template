//
// periph_stub.v - placeholder Wishbone slave + SDRAM master (UFO50 Pocket SoC, M3)
//
// Used by the M3 ufo50_blitter.v / ufo50_mixer.v stubs. It is also a reference for
// the two interfaces of docs/MEMORY_MAP.md sections 4 and 5:
//   0x00 R  ID
//   0x04-0x1C RW scratch registers
//   0x20 W  bit 0 = copy 32 bytes from SRC to DST through the SDRAM master port
//        R  bit 0 = busy, bit 1 = done (since last start)
//   0x24 RW SRC (CPU address 0x1xxxxxxx, 32-byte aligned)
//   0x28 RW DST (CPU address 0x1xxxxxxx, 32-byte aligned)
//
`default_nettype none

module periph_stub #(
    parameter [31:0] ID = 32'h5354_5542      // "STUB"
)(
    input  wire        clk,
    input  wire        rst,
    input  wire [15:2] wb_adr,
    input  wire [31:0] wb_dat_w,
    input  wire [3:0]  wb_sel,
    input  wire        wb_we,
    input  wire        wb_cyc,
    input  wire        wb_stb,
    output reg  [31:0] wb_dat_r,
    output reg         wb_ack,

    output wire        mem_cmd_valid,
    output wire        mem_cmd_we,
    output wire [25:2] mem_cmd_addr,
    output wire [2:0]  mem_cmd_len,
    output wire [31:0] mem_wdata,
    output wire [3:0]  mem_wstrb,
    input  wire        mem_cmd_ready,
    input  wire        mem_wready,
    input  wire [31:0] mem_rdata,
    input  wire        mem_rvalid
);
    reg [31:0] scratch [1:7];
    reg [31:0] src, dst;
    reg [31:0] buf_ [0:7];
    reg [1:0]  st;              // 0 idle, 1 read, 2 write
    reg        issued, done;
    reg [2:0]  beat;

    assign mem_cmd_valid = (st != 2'd0) && !issued;
    assign mem_cmd_we    = (st == 2'd2);
    assign mem_cmd_addr  = (st == 2'd2) ? {dst[25:5], 3'b000} : {src[25:5], 3'b000};
    assign mem_cmd_len   = 3'd7;
    assign mem_wdata     = buf_[beat];
    assign mem_wstrb     = 4'hF;

    integer i;
always @(posedge clk) begin
    wb_ack <= 1'b0;
    if (rst) begin
        st <= 2'd0; issued <= 1'b0; done <= 1'b0;
        src <= 32'd0; dst <= 32'd0;
        for (i = 1; i < 8; i = i + 1) scratch[i] <= 32'd0;
    end else begin
        if (wb_cyc && wb_stb && !wb_ack) begin
            wb_ack <= 1'b1;
            if (wb_we) begin
                if (wb_adr[15:5] == 11'd0 && wb_adr[4:2] != 3'd0) scratch[wb_adr[4:2]] <= wb_dat_w;
                if (wb_adr == 14'h08 && wb_dat_w[0] && st == 2'd0) begin
                    st <= 2'd1; issued <= 1'b0; beat <= 3'd0; done <= 1'b0;
                end
                if (wb_adr == 14'h09) src <= wb_dat_w;
                if (wb_adr == 14'h0A) dst <= wb_dat_w;
            end else begin
                if (wb_adr == 14'h00)                       wb_dat_r <= ID;
                else if (wb_adr[15:5] == 11'd0)             wb_dat_r <= scratch[wb_adr[4:2]];
                else if (wb_adr == 14'h08)                  wb_dat_r <= {30'd0, done, st != 2'd0};
                else if (wb_adr == 14'h09)                  wb_dat_r <= src;
                else if (wb_adr == 14'h0A)                  wb_dat_r <= dst;
                else                                        wb_dat_r <= 32'd0;
            end
        end
        if (mem_cmd_valid && mem_cmd_ready) issued <= 1'b1;
        if (st == 2'd1 && mem_rvalid) begin
            buf_[beat] <= mem_rdata;
            beat <= beat + 3'd1;
            if (beat == 3'd7) begin st <= 2'd2; issued <= 1'b0; end
        end
        if (st == 2'd2 && mem_wready) begin
            beat <= beat + 3'd1;
            if (beat == 3'd7) begin st <= 2'd0; issued <= 1'b0; done <= 1'b1; end
        end
    end
end

endmodule

`default_nettype wire
