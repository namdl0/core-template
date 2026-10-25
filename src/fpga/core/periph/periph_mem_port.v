// Adapter: peripherals' internal memory port (p_*) -> SoC SDRAM master port (s_*,
// docs/MEMORY_MAP.md section 5, v0.2). This is the one place to change if that contract changes.
//
// Internal port (Avalon-MM burst style), all on clk:
//   read : one handshake (p_valid && p_ready, p_write = 0) with p_addr (CPU byte address,
//          4-aligned) and p_len (1..256 beats of 32 bits); the data returns as p_len cycles of
//          p_rvalid/p_rdata, in order.
//   write: p_len handshakes (p_write = 1), one per beat, each with p_wdata/p_be; p_addr/p_len
//          constant over the burst. p_valid may drop between beats.
//   Requests complete in order; a read is accepted only after all earlier writes were issued.
// SoC port: one outstanding command, <= 8 beats, never crossing an aligned 32-byte block,
// word address = CPU address[25:2] (0x1xxx_xxxx and the 0x5xxx_xxxx alias map alike), write
// data pulled with s_wready (next beat on the bus the cycle after each pulse).
// Writes are staged per 32-byte block in two buffers, so collecting block k+1 overlaps the
// SDRAM transfer of block k.
module periph_mem_port (
    input  wire        clk,
    input  wire        rst,
    input  wire        p_valid,
    output wire        p_ready,
    input  wire [31:0] p_addr,
    input  wire        p_write,
    input  wire [8:0]  p_len,
    input  wire [31:0] p_wdata,
    input  wire [3:0]  p_be,
    output wire [31:0] p_rdata,
    output wire        p_rvalid,
    output reg         s_cmd_valid,
    output reg         s_cmd_we,
    output reg  [25:2] s_cmd_addr,
    output reg  [2:0]  s_cmd_len,
    output wire [31:0] s_wdata,
    output wire [3:0]  s_wstrb,
    input  wire        s_cmd_ready,
    input  wire        s_wready,
    input  wire [31:0] s_rdata,
    input  wire        s_rvalid
);
    // ---------------- write staging: 2 buffers x 8 words, filled by block offset
    reg [35:0] wbuf [0:15];              // {be, data}, index {buffer, word}
    reg [1:0]  full;                     // buffer handed to the issuer
    reg [2:0]  b_start [0:1]; reg [3:0] b_n [0:1]; reg [25:5] b_blk [0:1];
    reg        cbuf;                     // buffer being collected
    reg [3:0]  c_n;                      // beats collected into cbuf
    reg [25:2] c_addr;                   // word address of the next beat
    reg [8:0]  c_left;                   // beats left in the current burst (0 = idle)
    reg        ibuf;                     // buffer the issuer sends next
    reg [2:0]  i_beat;
    reg        busy_rd;
    wire       w_beat = p_valid && p_write && !busy_rd && !full[cbuf];
    assign p_ready = p_write ? w_beat : (!busy_rd && c_left == 0 && full == 2'b00 && !s_cmd_valid && !iss_w);
    wire [25:2] beat_addr = (c_left == 0) ? p_addr[25:2] : c_addr;
    wire        last_of_burst = (c_left == 0) ? (p_len == 9'd1) : (c_left == 9'd1);
    wire        last_of_block = beat_addr[4:2] == 3'd7;

    // ---------------- reads
    reg [8:0]  r_left; reg [25:2] r_addr; reg [3:0] r_chunk, r_got;
    assign p_rdata = s_rdata;
    assign p_rvalid = s_rvalid && busy_rd;
    wire [3:0] r_room = 4'd8 - r_addr[4:2];
    wire [3:0] r_n = (r_left < r_room) ? r_left[3:0] : r_room;

    reg iss_w;   // issuer busy with a write
    assign s_wdata = wbuf[{ibuf, b_start[ibuf] + i_beat}][31:0];
    assign s_wstrb = wbuf[{ibuf, b_start[ibuf] + i_beat}][35:32];

    always @(posedge clk) begin
        if (rst) begin
            full <= 0; cbuf <= 0; c_n <= 0; c_left <= 0; ibuf <= 0; i_beat <= 0; busy_rd <= 0;
            s_cmd_valid <= 0; iss_w <= 0; r_left <= 0;
        end else begin
            // collect write beats
            if (w_beat) begin
                wbuf[{cbuf, beat_addr[4:2]}] <= {p_be, p_wdata};
                if (c_n == 0) begin b_start[cbuf] <= beat_addr[4:2]; b_blk[cbuf] <= beat_addr[25:5]; end
                c_addr <= beat_addr + 1'b1;
                c_left <= (c_left == 0 ? p_len : c_left) - 1'b1;
                if (last_of_burst || last_of_block) begin
                    full[cbuf] <= 1; b_n[cbuf] <= c_n + 1'b1; c_n <= 0; cbuf <= ~cbuf;
                end else c_n <= c_n + 1'b1;
            end
            // issue
            if (!s_cmd_valid && !iss_w && !busy_rd) begin
                if (full[ibuf]) begin
                    s_cmd_valid <= 1; s_cmd_we <= 1; s_cmd_addr <= {b_blk[ibuf], b_start[ibuf]};
                    s_cmd_len <= b_n[ibuf] - 1'b1; i_beat <= 0; iss_w <= 1;
                end else if (p_valid && !p_write && p_ready) begin
                    busy_rd <= 1; r_left <= p_len; r_addr <= p_addr[25:2];
                end
            end
            if (s_cmd_valid && s_cmd_ready) s_cmd_valid <= 0;
            if (iss_w && s_wready) begin
                i_beat <= i_beat + 1'b1;
                if (i_beat + 1'b1 == b_n[ibuf][2:0] || b_n[ibuf] == 4'd8 && i_beat == 3'd7) begin
                    iss_w <= 0; full[ibuf] <= 0; ibuf <= ~ibuf;
                end
            end
            // read chunks
            if (busy_rd && !s_cmd_valid) begin
                if (r_chunk == 0) begin
                    if (r_left == 0) busy_rd <= 0;
                    else begin
                        s_cmd_valid <= 1; s_cmd_we <= 0; s_cmd_addr <= r_addr; s_cmd_len <= r_n - 1'b1;
                        r_chunk <= r_n; r_got <= 0; r_addr <= r_addr + r_n; r_left <= r_left - r_n;
                    end
                end
            end
            if (busy_rd && s_rvalid) begin
                if (r_got + 1'b1 == r_chunk) begin r_chunk <= 0; end
                r_got <= r_got + 1'b1;
            end
            if (!busy_rd) r_chunk <= 0;
        end
    end
endmodule
