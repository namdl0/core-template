// UFO 50 audio mixer: Wishbone B4 classic slave (64 KB window), command FIFO, mix_core,
// output sample FIFO and the Pocket's I2S DAC interface. Register map: docs/AUDIO_MIXER.md.
module mixer #(
    parameter CF_AW = 6,     // command FIFO depth (64)
    parameter OF_AW = 4      // output FIFO depth (16 samples = 0.33 ms of slack)
) (
    input  wire        clk,          // system clock
    input  wire        rst,
    input  wire        clk_74a,      // APF 74.25 MHz (I2S timing)
    // Wishbone B4 classic slave
    input  wire [15:2] wb_adr_i,
    input  wire [31:0] wb_dat_i,
    output reg  [31:0] wb_dat_o,
    input  wire [3:0]  wb_sel_i,
    input  wire        wb_we_i,
    input  wire        wb_cyc_i,
    input  wire        wb_stb_i,
    output reg         wb_ack_o,
    // SDRAM master (reads only)
    output wire        mem_cmd_valid,
    output wire        mem_cmd_we,
    output wire [25:2] mem_cmd_addr,
    output wire [2:0]  mem_cmd_len,
    output wire [31:0] mem_wdata,
    output wire [3:0]  mem_wstrb,
    input  wire        mem_cmd_ready,
    input  wire        mem_wready,
    input  wire [31:0] mem_rdata,
    input  wire        mem_rvalid,
    // output sample handshake: SoC pulses audio_tick at 48 kHz, latches audio_l/audio_r
    input  wire        audio_tick,
    output reg  [15:0] audio_l,
    output reg  [15:0] audio_r,
    // optional standalone I2S path (unused by the SoC integration; kept for a bare core-template
    // build or bench test). Tie clk_74a low and the pins are unused if audio_tick is driven instead.
    output wire        audio_mclk,
    output wire        audio_lrck,
    output wire        audio_dac
);
    reg en, soft_rst; wire crst = rst || soft_rst;
    wire req = wb_cyc_i && wb_stb_i && !wb_ack_o;
    wire [10:0] key = wb_adr_i[12:2];
    // writes to 0x0010 (master), 0x0800-0x087F (groups), 0x1000-0x17FF (voices) are commands
    wire is_cmd = !wb_adr_i[15] && !wb_adr_i[14] && !wb_adr_i[13] &&
                  (key == 11'h004 || key[10:5] == 6'b010000 || key[10:9] == 2'b10);
    wire cf_full, cf_empty, cf_rd; wire [42:0] cf_data; wire [CF_AW:0] cf_count;
    wire push = req && wb_we_i && is_cmd && !cf_full;
    periph_fifo #(.AW(CF_AW), .DW(43)) cfifo (.clk(clk), .rst(crst), .wr_en(push), .wr_data({key, wb_dat_i}),
        .rd_en(cf_rd), .rd_data(cf_data), .empty(cf_empty), .full(cf_full), .count(cf_count));

    // voice status RAM (read by the CPU)
    wire st_we; wire [5:0] st_wa; wire [31:0] st_wd, st_rd;
    periph_ram #(.AW(6), .DW(32)) stram (.clk(clk), .we(st_we), .wa(st_wa), .wd(st_wd), .ra({key[8:4], key[0]}), .rd(st_rd));

    wire out_valid; wire [15:0] out_l, out_r; wire [31:0] samples; wire [15:0] last_cycles;
    wire of_full, of_empty; wire [OF_AW:0] of_count; wire [31:0] of_data; reg of_rd;
    wire m_valid, m_ready; wire [31:0] m_addr; wire [8:0] m_len; wire [31:0] m_rdata; wire m_rvalid;
    mix_core core (.clk(clk), .rst(crst), .en(en), .cf_empty(cf_empty), .cf_rd(cf_rd), .cf_data(cf_data),
        .out_valid(out_valid), .out_ready(!of_full), .out_l(out_l), .out_r(out_r),
        .st_we(st_we), .st_wa(st_wa), .st_wd(st_wd), .samples(samples), .last_cycles(last_cycles),
        .m_valid(m_valid), .m_ready(m_ready), .m_addr(m_addr), .m_len(m_len), .m_rdata(m_rdata), .m_rvalid(m_rvalid));
    periph_fifo #(.AW(OF_AW), .DW(32)) ofifo (.clk(clk), .rst(crst), .wr_en(out_valid && !of_full), .wr_data({out_r, out_l}),
        .rd_en(of_rd), .rd_data(of_data), .empty(of_empty), .full(of_full), .count(of_count));
    periph_mem_port mport (.clk(clk), .rst(crst),
        .p_valid(m_valid), .p_ready(m_ready), .p_addr(m_addr), .p_write(1'b0), .p_len(m_len),
        .p_wdata(32'd0), .p_be(4'd0), .p_rdata(m_rdata), .p_rvalid(m_rvalid),
        .s_cmd_valid(mem_cmd_valid), .s_cmd_we(mem_cmd_we), .s_cmd_addr(mem_cmd_addr), .s_cmd_len(mem_cmd_len),
        .s_wdata(mem_wdata), .s_wstrb(mem_wstrb), .s_cmd_ready(mem_cmd_ready), .s_wready(mem_wready),
        .s_rdata(mem_rdata), .s_rvalid(mem_rvalid));

    // ---------------------------------------------------------------- I2S sample hand-off
    // The I2S side toggles i2s_req when it loads hold[] into its shifter; we then replace hold[]
    // with the next FIFO sample. hold[] is stable for a whole 48 kHz frame before it is sampled.
    // Output sample pop: one decision per cycle, feeding either the SoC's audio_tick path
    // (normal integration: clk_74a tied low, i2s_req never toggles) or the standalone I2S path
    // (bare core-template build: audio_tick tied low). Both read the same FIFO through the one
    // read port, so at most one path is active in a given build.
    reg [31:0] hold, hold_i2s; reg pop_d; reg [31:0] underruns;
    wire       i2s_req; reg [2:0] req_s; wire pop_tick = audio_tick, pop_i2s = req_s[2] != req_s[1];
    always @(posedge clk) begin
        req_s <= {req_s[1:0], i2s_req};
        of_rd <= 0; pop_d <= of_rd;
        if (crst) begin hold <= 0; hold_i2s <= 0; underruns <= 0; audio_l <= 0; audio_r <= 0; end
        else begin
            if (pop_tick && !of_empty) of_rd <= 1;
            else if (pop_tick && of_empty && en) underruns <= underruns + 1'b1;
            else if (pop_i2s && !of_empty) of_rd <= 1;
            if (pop_d) begin hold <= of_data; hold_i2s <= of_data; audio_l <= of_data[15:0]; audio_r <= of_data[31:16]; end
        end
    end
    i2s_tx i2s (.clk_74a(clk_74a), .sample(hold_i2s), .req(i2s_req), .audio_mclk(audio_mclk), .audio_lrck(audio_lrck), .audio_dac(audio_dac));

    // ---------------------------------------------------------------- registers
    reg [15:0] max_cycles;
    wire [15:0] cf_free = (16'd1 << CF_AW) - cf_count;
    always @(posedge clk) begin
        soft_rst <= 0;
        if (crst) max_cycles <= 0; else if (last_cycles > max_cycles) max_cycles <= last_cycles;
        if (rst) begin wb_ack_o <= 0; en <= 0; end
        else begin
            wb_ack_o <= 0;
            if (req && !(wb_we_i && is_cmd && cf_full)) begin
                wb_ack_o <= 1;
                if (wb_we_i && key == 11'h002) begin en <= wb_dat_i[0]; soft_rst <= wb_dat_i[2]; end
            end
        end
    end
    // read data (status RAM read address is the request address: data valid one cycle later = ack cycle)
    always @(*) begin
        case (key)
            11'h000: wb_dat_o = 32'h4D495831;                        // "MIX1"
            11'h001: wb_dat_o = {cf_free, {(16-OF_AW-1){1'b0}}, of_count};
            11'h002: wb_dat_o = {31'd0, en};
            11'h003: wb_dat_o = samples;
            11'h005: wb_dat_o = underruns;
            11'h006: wb_dat_o = {max_cycles, last_cycles};
            default: wb_dat_o = (key[10:9] == 2'b10 && key[3:1] == 3'd0) ? st_rd : 32'd0;
        endcase
    end
endmodule

// I2S transmitter for the Analogue Pocket DAC. Clocking and bit timing follow Analogue's
// core-template audio generator and agg23's sound_i2s.sv (MIT, github.com/agg23/analogue-pocket-utils):
// MCLK = 12.288 MHz from clk_74a by a fractional accumulator, SCLK = MCLK/4 = 3.072 MHz,
// LRCK = SCLK/64 = 48 kHz, 32-bit slots, 16-bit signed samples MSB first, one SCLK after the
// LRCK edge, data changing on the falling SCLK edge. As in sound_i2s.sv the {right, left}
// word is loaded when LRCK rises: right is sent while LRCK is high, left while it is low
// (standard I2S). The DAC derives SCLK from MCLK; only MCLK, LRCK and data are pins.
module i2s_tx (
    input  wire        clk_74a,
    input  wire [31:0] sample,       // {right, left}, from another clock domain, stable for a frame
    output reg         req,          // toggles after each load of `sample`
    output reg         audio_mclk,
    output reg         audio_lrck,
    output reg         audio_dac
);
    reg [21:0] accum = 0;
    localparam [20:0] CYCLE_48KHZ = 21'd122880 * 2;
    initial begin audio_mclk = 0; audio_lrck = 0; audio_dac = 0; req = 0; end
    always @(posedge clk_74a) begin
        accum <= accum + CYCLE_48KHZ;
        if (accum >= 22'd742500) begin audio_mclk <= ~audio_mclk; accum <= accum - 22'd742500 + CYCLE_48KHZ; end
    end
    reg [1:0] div = 0; reg mclk_d = 0;
    wire sclk = div[1];
    always @(posedge clk_74a) begin
        mclk_d <= audio_mclk;
        if (audio_mclk && !mclk_d) div <= div + 1'b1;
    end
    reg [31:0] shift = 0; reg [4:0] cnt = 0; reg sclk_d = 0;
    always @(posedge clk_74a) begin
        sclk_d <= sclk;
        if (sclk_d && !sclk) begin
            audio_dac <= shift[31];
            cnt <= cnt + 1'b1;
            if (cnt == 5'd31) begin
                audio_lrck <= ~audio_lrck;
                if (!audio_lrck) begin shift <= sample; req <= ~req; end
            end else if (cnt < 5'd16) shift <= {shift[30:0], 1'b0};
        end
    end
endmodule
