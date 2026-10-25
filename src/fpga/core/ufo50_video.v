//
// ufo50_video.v
//
// UFO 50 Pocket port - milestone M1 video timing + test pattern.
//
// Video mode: 384x216 active, 16:9, ~60 Hz progressive.
//
// Timing (all counts in pixel clocks / lines):
//
//   pixel clock  12.288 MHz (template PLL outclk_0, unchanged; 90 deg copy on outclk_1)
//   H_TOTAL      512   = 64 back porch + 384 active + 64 front porch
//   V_TOTAL      400   = 16 back porch + 216 active + 168 front porch
//   frame        512 * 400 = 204,800 clocks
//   refresh      12,288,000 / 204,800 = 60.000 Hz
//                (the PLL actually reports 12.287999 MHz -> 59.99999 Hz)
//
// 12.288 MHz is exactly 60 Hz * 204,800, so choosing H_TOTAL * V_TOTAL = 204,800
// lets this core keep the template's generated PLL as-is (no IP regeneration).
// The large vertical blank (184 lines, ~46% of the frame) is harmless for the
// Pocket scaler, which only captures pixels where DE is high, and later gives
// the blitter a long window to flip/fill buffers.
//
// Sync convention (same as Analogue's core-template):
//   VS: one-clock pulse at x=0,y=0 (inside the vertical back porch)
//   HS: one-clock pulse at x=HS_X on every line (3 clocks after VS on line 0)
//   DE: high only inside the 384x216 window; RGB is forced to 0 outside it
//   skip: always 0 (every pixel in the DE window is new)
// All outputs are registered on the same edge, so they stay aligned.
//
// Test pattern (coordinates are inside the active window, 0..383 x 0..215):
//   - 1 px white border exactly on the outermost rows/columns, 1 px red ring
//     just inside it: if all four white edges are visible, nothing is cropped.
//   - 8 SMPTE-style colour bars, 48 px wide each, rows 0..143
//   - horizontal grey ramp, rows 144..175
//   - 1x1 checkerboard (left half) and 2x2 checkerboard (right half), rows 176..215
//   - a 24x24 box bouncing around the active area (2 px/frame in x, 1 px/frame in y)
//
// Controller 1 test hooks (cont1_key bits, synchronised into this domain):
//   A      (bit 4)  box turns cyan instead of orange
//   B      (bit 5)  freeze the box
//   Select (bit 14) greyscale output
//   Start  (bit 15) invert colours
//
// M3 (EXT = 1): the module also exports its counters (hcount/vcount) for the
// framebuffer scanout and selects the output source with src_mode (any clock
// domain, quasi-static): 0 = border_rgb, 1 = fb_rgb (framebuffer pixel for the
// current counters), 2/3 = the M1 test pattern above. With EXT = 0 (default) the
// new inputs are ignored and the module behaves exactly as in M1.
//

`default_nettype none

module ufo50_video #(
    parameter H_ACTIVE = 384,
    parameter H_BPORCH = 64,
    parameter H_TOTAL  = 512,
    parameter V_ACTIVE = 216,
    parameter V_BPORCH = 16,
    parameter V_TOTAL  = 400,
    parameter HS_X     = 3,
    parameter BOX      = 24,
    parameter EXT      = 0
)(
    input  wire         clk,        // pixel clock
    input  wire         reset_n,    // active-low reset, any clock domain
    input  wire [15:0]  keys,       // cont1_key[15:0], any clock domain

    output reg  [23:0]  rgb,
    output reg          de,
    output reg          hs,
    output reg          vs,
    output wire         skip,
    output reg  [15:0]  frame_count,

    // M3 framebuffer hooks (used when EXT = 1)
    input  wire [1:0]   src_mode,
    input  wire [23:0]  fb_rgb,
    input  wire [23:0]  border_rgb,
    output wire [9:0]   hcount,
    output wire [9:0]   vcount
);

assign skip = 1'b0;

// ---------------------------------------------------------------------------
// reset: asynchronous assert, synchronous release in the pixel clock domain
// ---------------------------------------------------------------------------
    reg [1:0]   rst_sync = 2'b00;
    wire        rst_n_v = rst_sync[1];

always @(posedge clk or negedge reset_n) begin
    if (~reset_n)
        rst_sync <= 2'b00;
    else
        rst_sync <= {rst_sync[0], 1'b1};
end

// ---------------------------------------------------------------------------
// controller bits: two-flop synchroniser (buttons are quasi-static)
// ---------------------------------------------------------------------------
    reg [15:0]  keys_m = 16'h0;
    reg [15:0]  keys_s = 16'h0;

always @(posedge clk) begin
    keys_m <= keys;
    keys_s <= keys_m;
end

    wire        key_a      = keys_s[4];
    wire        key_b      = keys_s[5];
    wire        key_select = keys_s[14];
    wire        key_start  = keys_s[15];

// ---------------------------------------------------------------------------
// counters
// ---------------------------------------------------------------------------
    reg [9:0]   x_count = 10'd0;
    reg [9:0]   y_count = 10'd0;

    wire        h_active = (x_count >= H_BPORCH) && (x_count < H_BPORCH + H_ACTIVE);
    wire        v_active = (y_count >= V_BPORCH) && (y_count < V_BPORCH + V_ACTIVE);
    wire        active   = h_active && v_active;

    // coordinates inside the active window (only meaningful while active)
    localparam [9:0] HB = H_BPORCH;
    localparam [9:0] VB = V_BPORCH;
    wire [9:0]  vx = x_count - HB;
    wire [9:0]  vy = y_count - VB;

    wire        frame_start = (x_count == 10'd0) && (y_count == 10'd0);

    assign hcount = x_count;
    assign vcount = y_count;

// ---------------------------------------------------------------------------
// bouncing box state (updated once per frame, at x=0,y=0, i.e. in vblank)
// ---------------------------------------------------------------------------
    reg [9:0]   box_x = 10'd40;
    reg [9:0]   box_y = 10'd20;
    reg         box_dx = 1'b1;     // 1 = moving right
    reg         box_dy = 1'b1;     // 1 = moving down

    localparam [9:0] BOX_X_MAX = H_ACTIVE - BOX;
    localparam [9:0] BOX_Y_MAX = V_ACTIVE - BOX;

always @(posedge clk) begin
    if (~rst_n_v) begin
        x_count     <= 10'd0;
        y_count     <= 10'd0;
        frame_count <= 16'd0;
        box_x       <= 10'd40;
        box_y       <= 10'd20;
        box_dx      <= 1'b1;
        box_dy      <= 1'b1;
    end else begin
        if (x_count == H_TOTAL - 1) begin
            x_count <= 10'd0;
            if (y_count == V_TOTAL - 1)
                y_count <= 10'd0;
            else
                y_count <= y_count + 10'd1;
        end else begin
            x_count <= x_count + 10'd1;
        end

        if (frame_start) begin
            frame_count <= frame_count + 16'd1;

            if (~key_b) begin
                // x: 2 px per frame
                if (box_dx) begin
                    if (box_x + 10'd2 >= BOX_X_MAX) begin
                        box_x  <= BOX_X_MAX;
                        box_dx <= 1'b0;
                    end else
                        box_x  <= box_x + 10'd2;
                end else begin
                    if (box_x <= 10'd2) begin
                        box_x  <= 10'd0;
                        box_dx <= 1'b1;
                    end else
                        box_x  <= box_x - 10'd2;
                end
                // y: 1 px per frame
                if (box_dy) begin
                    if (box_y + 10'd1 >= BOX_Y_MAX) begin
                        box_y  <= BOX_Y_MAX;
                        box_dy <= 1'b0;
                    end else
                        box_y  <= box_y + 10'd1;
                end else begin
                    if (box_y <= 10'd1) begin
                        box_y  <= 10'd0;
                        box_dy <= 1'b1;
                    end else
                        box_y  <= box_y - 10'd1;
                end
            end
        end
    end
end

// ---------------------------------------------------------------------------
// pattern (combinational from the current counters, registered below)
// ---------------------------------------------------------------------------
    // grey ramp: vx * 171 / 256 maps 0..383 onto 0..255
    wire [17:0] ramp_mul = vx * 10'd171;
    wire [7:0]  ramp     = ramp_mul[15:8];

    wire        in_box = (vx >= box_x) && (vx < box_x + BOX) &&
                         (vy >= box_y) && (vy < box_y + BOX);

    wire        edge_outer = (vx == 10'd0) || (vx == H_ACTIVE - 1) ||
                             (vy == 10'd0) || (vy == V_ACTIVE - 1);
    wire        edge_inner = (vx == 10'd1) || (vx == H_ACTIVE - 2) ||
                             (vy == 10'd1) || (vy == V_ACTIVE - 2);

    reg [23:0]  pattern;

always @(*) begin
    // background regions
    if (vy < 10'd144) begin
        if      (vx < 10'd48)  pattern = 24'hFFFFFF;   // white
        else if (vx < 10'd96)  pattern = 24'hFFFF00;   // yellow
        else if (vx < 10'd144) pattern = 24'h00FFFF;   // cyan
        else if (vx < 10'd192) pattern = 24'h00FF00;   // green
        else if (vx < 10'd240) pattern = 24'hFF00FF;   // magenta
        else if (vx < 10'd288) pattern = 24'hFF0000;   // red
        else if (vx < 10'd336) pattern = 24'h0000FF;   // blue
        else                   pattern = 24'h000000;   // black
    end else if (vy < 10'd176) begin
        pattern = {ramp, ramp, ramp};
    end else if (vx < 10'd192) begin
        pattern = (vx[0] ^ vy[0]) ? 24'hFFFFFF : 24'h000000;
    end else begin
        pattern = (vx[1] ^ vy[1]) ? 24'hFFFFFF : 24'h000000;
    end

    // moving box
    if (in_box)
        pattern = key_a ? 24'h00C0FF : 24'hFF8000;

    // border: red ring 1 px inside, white ring on the outermost pixels
    if (edge_inner)
        pattern = 24'hFF0000;
    if (edge_outer)
        pattern = 24'hFFFFFF;
end

    // optional greyscale (Select) and invert (Start)
    wire [15:0] luma = pattern[23:16] * 8'd77 + pattern[15:8] * 8'd150 + pattern[7:0] * 8'd29;
    wire [23:0] pat_grey = key_select ? {luma[15:8], luma[15:8], luma[15:8]} : pattern;
    wire [23:0] pat_out  = key_start  ? ~pat_grey : pat_grey;

    // source select (M3)
    reg  [1:0]  mode_m = 2'd2, mode_s = 2'd2;
    reg  [23:0] border_m = 24'd0, border_s = 24'd0;
always @(posedge clk) begin
    mode_m   <= src_mode;   mode_s   <= mode_m;
    border_m <= border_rgb; border_s <= border_m;
end
    wire [23:0] pix_out = (EXT == 0)        ? pat_out :
                          mode_s[1]         ? pat_out :
                          mode_s[0]         ? fb_rgb  : border_s;

// ---------------------------------------------------------------------------
// registered outputs
// ---------------------------------------------------------------------------
always @(posedge clk) begin
    if (~rst_n_v) begin
        rgb <= 24'h0;
        de  <= 1'b0;
        hs  <= 1'b0;
        vs  <= 1'b0;
    end else begin
        vs  <= frame_start;
        hs  <= (x_count == HS_X);
        de  <= active;
        rgb <= active ? pix_out : 24'h0;
    end
end

endmodule

`default_nettype wire
