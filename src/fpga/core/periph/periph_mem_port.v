// Adapter between the peripherals' internal memory port (p_*) and the SoC's SDRAM
// master request port (s_*). This is the ONE place to change when docs/MEMORY_MAP.md
// (branch ufo50-m3) fixes the SoC port.
//
// Internal port semantics (Avalon-MM burst style), all on clk:
//   read : one handshake (p_valid && p_ready, p_write = 0) carries p_addr (byte address,
//          4-aligned) and p_len (1..256 beats of 32 bits). The data comes back later as
//          p_len cycles of p_rvalid with p_rdata, in request order. Several reads may be
//          outstanding. A request is held until accepted.
//   write: p_len handshakes (p_write = 1), one per beat, each with p_wdata/p_be; p_addr and
//          p_len are constant for the whole burst. p_valid may drop between beats.
//   Requests are performed in order: a read issued after a write sees that write.
// Today the SoC port is assumed identical, so this is a pass-through.
module periph_mem_port (
    input  wire        clk,
    input  wire        p_valid,
    output wire        p_ready,
    input  wire [31:0] p_addr,
    input  wire        p_write,
    input  wire [8:0]  p_len,
    input  wire [31:0] p_wdata,
    input  wire [3:0]  p_be,
    output wire [31:0] p_rdata,
    output wire        p_rvalid,
    output wire        s_valid,
    input  wire        s_ready,
    output wire [31:0] s_addr,
    output wire        s_write,
    output wire [8:0]  s_len,
    output wire [31:0] s_wdata,
    output wire [3:0]  s_be,
    input  wire [31:0] s_rdata,
    input  wire        s_rvalid
);
    assign s_valid = p_valid; assign p_ready = s_ready; assign s_addr = p_addr; assign s_write = p_write;
    assign s_len = p_len; assign s_wdata = p_wdata; assign s_be = p_be;
    assign p_rdata = s_rdata; assign p_rvalid = s_rvalid;
endmodule
