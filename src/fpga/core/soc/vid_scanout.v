//
// vid_scanout.v - framebuffer scanout for the UFO50 Pocket SoC (M3)
//
// Reads a 384x216 framebuffer from SDRAM one line ahead into a dual-clock line
// buffer (2 lines x 512 words), and feeds pixels to ufo50_video in the 12.288 MHz
// pixel clock domain. Two formats (fmt32, latched by sysregs at vblank):
//   0: RGB565, 2 pixels/word, stride 768 B, 24 bursts/line (M3)
//   1: ABGR8888 (0xAABBGGRR, what the blitter writes), 1 pixel/word, stride
//      1536 B, 48 bursts/line, full 8-bit RGB out (M4) Timing comes from ufo50_video's counters, so the
// M1 timing (512x400 total, 60.000 Hz) is unchanged.
//
// Pixel latency: ufo50_video registers rgb from the current counters. This module
// reads the line buffer at (vx + 1) so that pix_rgb, valid during the cycle after the
// RAM read, matches the counters of that cycle.
//
// Fetch: at x == 0 of video line y (VB-1 <= y <= VB+V_ACTIVE-2), active line
// y-VB+1 is requested. The sys side reads 24 (565) or 48 (8888) bursts of 32
// bytes from fb_base + line*stride (line time is ~2400 sys clocks).
//
`default_nettype none

module vid_scanout #(
    parameter HB = 64,          // H back porch (first active x)
    parameter VB = 16,          // V back porch (first active y)
    parameter H_ACTIVE = 384,
    parameter V_ACTIVE = 216
)(
    input  wire         clk_sys,
    input  wire         rst_sys,
    input  wire [25:0]  fb_base,        // SDRAM byte offset of the front buffer (latched by sysregs at vblank)
    input  wire         fmt32,          // 1 = ABGR8888, 0 = RGB565 (latched by sysregs at vblank)

    // SDRAM master port (read only)
    output wire         p_valid,
    input  wire         p_ready,
    output wire [25:2]  p_addr,
    output wire [2:0]   p_len,
    input  wire         p_rvalid,
    input  wire [31:0]  p_rdata,

    output wire         vblank_pulse,   // sys domain, one cycle: start of vertical blank
    output wire         vactive_pulse,  // sys domain, one cycle: first active line starts
    output reg  [7:0]   line,           // last line fetched

    input  wire         clk_vid,
    input  wire [9:0]   vid_x,
    input  wire [9:0]   vid_y,
    output wire [23:0]  pix_rgb
);

// ---------------------------------------------------------------- video side
    localparam [9:0] Y_FIRST_REQ = VB - 1;
    localparam [9:0] Y_LAST_REQ  = VB + V_ACTIVE - 2;
    localparam [9:0] Y_VBLANK    = VB + V_ACTIVE;
    localparam [9:0] HBm1        = HB - 1;

    reg        req_t = 1'b0, vbl_t = 1'b0, act_t = 1'b0;
    reg [7:0]  req_line_v = 8'd0;

    wire [9:0] y_next = vid_y - Y_FIRST_REQ;       // active index of the line to fetch

always @(posedge clk_vid) begin
    if (vid_x == 10'd0) begin
        if (vid_y >= Y_FIRST_REQ && vid_y <= Y_LAST_REQ) begin
            req_line_v <= y_next[7:0];
            req_t      <= ~req_t;
        end
        if (vid_y == Y_VBLANK) vbl_t <= ~vbl_t;
        if (vid_y == VB)       act_t <= ~act_t;
    end
end

    // format in the video domain (quasi-static: changes only at vblank, long
    // before the next line fetch, so a plain 2-FF synchroniser is enough)
    reg [1:0]  fmt_v = 2'b00;
always @(posedge clk_vid) fmt_v <= {fmt_v[0], fmt32};
    wire       f32_v = fmt_v[1];

    // line buffer read: word address {line parity, word index within the line}
    wire [9:0] vx1  = vid_x - HBm1;                // = active x + 1
    wire [9:0] vy   = vid_y - VB[9:0];
    wire [9:0] radr = f32_v ? {vy[0], vx1[8:0]} : {vy[0], 1'b0, vx1[8:1]};
    reg  [31:0] lb_q;
    reg         half_sel, f32_q;
    reg  [31:0] lbuf [0:1023];

always @(posedge clk_vid) begin
    lb_q     <= lbuf[radr];
    half_sel <= vx1[0];
    f32_q    <= f32_v;
end

    wire [15:0] px = half_sel ? lb_q[31:16] : lb_q[15:0];
    assign pix_rgb = f32_q ? {lb_q[7:0], lb_q[15:8], lb_q[23:16]}
                           : {px[15:11], px[15:13], px[10:5], px[10:9], px[4:0], px[4:2]};

// ------------------------------------------------------------------ sys side
    reg [2:0] req_s, vbl_s, act_s;
always @(posedge clk_sys) begin
    req_s <= {req_s[1:0], req_t};
    vbl_s <= {vbl_s[1:0], vbl_t};
    act_s <= {act_s[1:0], act_t};
end
    assign vblank_pulse  = vbl_s[2] ^ vbl_s[1];
    assign vactive_pulse = act_s[2] ^ act_s[1];
    wire   req_pulse     = req_s[2] ^ req_s[1];

    reg        busy;
    reg [5:0]  burst;           // 0..23 (565) or 0..47 (8888)
    reg        lfmt;            // format of the line being fetched
    reg        issued;
    reg [2:0]  beat;
    reg [7:0]  fline;
    reg [25:0] laddr;           // byte offset of the current line

    assign p_valid = busy && !issued;
    assign p_addr  = laddr[25:2] + {15'd0, burst, 3'b000};
    assign p_len   = 3'd7;

    // line buffer write
    wire [9:0] wadr = {fline[0], burst, beat};
always @(posedge clk_sys)
    if (p_rvalid && busy) lbuf[wadr] <= p_rdata;

always @(posedge clk_sys) begin
    if (rst_sys) begin
        busy <= 1'b0;
        line <= 8'd0;
    end else if (!busy) begin
        if (req_pulse) begin
            busy   <= 1'b1;
            fline  <= req_line_v;          // stable: changes once per video line
            lfmt   <= fmt32;
            // stride 768 = 512 + 256, or 1536 = 1024 + 512
            laddr  <= fmt32 ? fb_base + {req_line_v, 10'd0} + {1'b0, req_line_v, 9'd0}
                            : fb_base + {req_line_v, 9'd0}  + {1'b0, req_line_v, 8'd0};
            burst  <= 6'd0;
            beat   <= 3'd0;
            issued <= 1'b0;
        end
    end else begin
        if (p_ready) issued <= 1'b1;
        if (p_rvalid) begin
            beat <= beat + 3'd1;
            if (beat == 3'd7) begin
                issued <= 1'b0;
                if (burst == (lfmt ? 6'd47 : 6'd23)) begin
                    busy <= 1'b0;
                    line <= fline;
                end else
                    burst <= burst + 6'd1;
            end
        end
    end
end

endmodule

`default_nettype wire
