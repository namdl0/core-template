// UFO 50 blitter: Wishbone B4 classic slave (64 KB window) + command FIFO + engine.
// Register map and command format: docs/BLITTER.md.
module blitter #(
    parameter FIFO_AW   = 9,     // command FIFO depth 2^FIFO_AW words (512 = 64 commands)
    parameter MAX_BURST = 64
) (
    input  wire        clk,
    input  wire        rst,
    // Wishbone B4 classic slave
    input  wire [15:2] wb_adr_i,
    input  wire [31:0] wb_dat_i,
    output reg  [31:0] wb_dat_o,
    input  wire [3:0]  wb_sel_i,
    input  wire        wb_we_i,
    input  wire        wb_cyc_i,
    input  wire        wb_stb_i,
    output reg         wb_ack_o,
    output wire        irq,
    // SDRAM master (SoC side of periph_mem_port)
    output wire        mem_valid,
    input  wire        mem_ready,
    output wire [31:0] mem_addr,
    output wire        mem_write,
    output wire [8:0]  mem_len,
    output wire [31:0] mem_wdata,
    output wire [3:0]  mem_be,
    input  wire [31:0] mem_rdata,
    input  wire        mem_rvalid
);
    reg  irq_en, irq_pend, soft_rst, pal_flush;
    wire erst = rst || soft_rst;

    wire        cf_rd, cf_empty, cf_full; wire [31:0] cf_data; wire [FIFO_AW:0] cf_count;
    wire        req = wb_cyc_i && wb_stb_i && !wb_ack_o;
    wire        is_push = wb_adr_i[15] || (wb_adr_i[14:2] == 13'h10);   // 0x8000-0xFFFF or 0x0040
    wire        push = req && wb_we_i && is_push && !cf_full;
    periph_fifo #(.AW(FIFO_AW), .DW(32)) cfifo (.clk(clk), .rst(erst), .wr_en(push), .wr_data(wb_dat_i),
        .rd_en(cf_rd), .rd_data(cf_data), .empty(cf_empty), .full(cf_full), .count(cf_count));

    wire busy, fence_irq; wire [31:0] fence, perf_busy, perf_pixels, perf_memwait;
    wire        m_valid, m_ready, m_write, m_rvalid; wire [31:0] m_addr, m_wdata, m_rdata; wire [8:0] m_len; wire [3:0] m_be;
    blit_engine #(.MAX_BURST(MAX_BURST)) eng (
        .clk(clk), .rst(erst), .cf_empty(cf_empty), .cf_rd(cf_rd), .cf_data(cf_data), .pal_flush(pal_flush),
        .busy(busy), .fence(fence), .fence_irq(fence_irq),
        .perf_busy(perf_busy), .perf_pixels(perf_pixels), .perf_memwait(perf_memwait),
        .m_valid(m_valid), .m_ready(m_ready), .m_addr(m_addr), .m_write(m_write), .m_len(m_len),
        .m_wdata(m_wdata), .m_be(m_be), .m_rdata(m_rdata), .m_rvalid(m_rvalid));
    periph_mem_port mport (
        .clk(clk),
        .p_valid(m_valid), .p_ready(m_ready), .p_addr(m_addr), .p_write(m_write), .p_len(m_len),
        .p_wdata(m_wdata), .p_be(m_be), .p_rdata(m_rdata), .p_rvalid(m_rvalid),
        .s_valid(mem_valid), .s_ready(mem_ready), .s_addr(mem_addr), .s_write(mem_write), .s_len(mem_len),
        .s_wdata(mem_wdata), .s_be(mem_be), .s_rdata(mem_rdata), .s_rvalid(mem_rvalid));

    assign irq = irq_en && irq_pend;
    wire [15:0] free = (16'd1 << FIFO_AW) - cf_count;

    always @(posedge clk) begin
        soft_rst <= 0; pal_flush <= 0;
        if (rst) begin
            wb_ack_o <= 0; irq_en <= 0; irq_pend <= 0;
        end else begin
            if (fence_irq) irq_pend <= 1;
            wb_ack_o <= 0;
            if (req && !(wb_we_i && is_push && cf_full)) begin
                wb_ack_o <= 1;
                if (wb_we_i && !wb_adr_i[15]) case (wb_adr_i[14:2])
                    13'h02: begin irq_en <= wb_dat_i[0]; pal_flush <= wb_dat_i[1]; soft_rst <= wb_dat_i[2]; end
                    13'h04: if (wb_dat_i[0]) irq_pend <= 0;
                    default: ;
                endcase
                case (wb_adr_i[14:2])
                    13'h00: wb_dat_o <= 32'h424C5431;                               // "BLT1"
                    13'h01: wb_dat_o <= {free, 13'd0, cf_empty, irq_pend, busy};
                    13'h02: wb_dat_o <= {31'd0, irq_en};
                    13'h03: wb_dat_o <= fence;
                    13'h05: wb_dat_o <= perf_busy;
                    13'h06: wb_dat_o <= perf_pixels;
                    13'h07: wb_dat_o <= perf_memwait;
                    default: wb_dat_o <= 32'd0;
                endcase
            end
        end
    end
endmodule
