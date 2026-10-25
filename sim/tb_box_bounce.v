//
// tb_box_bounce.v - checks the bouncing-box state machine of ufo50_video.v
// over many frames. The DUT is built with tiny H/V totals so a "frame" is only
// 32 clocks; the box limits depend only on H_ACTIVE/V_ACTIVE/BOX.
//
//   iverilog -g2005 -Wall -o sim/tb_box.vvp sim/tb_box_bounce.v src/fpga/core/ufo50_video.v
//   vvp sim/tb_box.vvp
//
`timescale 1ns/1ps
`default_nettype none

module tb_box_bounce;

    reg clk = 1'b0;
    reg reset_n = 1'b0;
    always #5 clk = ~clk;

    wire [23:0] rgb;
    wire de, hs, vs, skip;
    wire [15:0] frame_count;

    ufo50_video #(
        .H_ACTIVE(384), .H_BPORCH(0), .H_TOTAL(8),
        .V_ACTIVE(216), .V_BPORCH(0), .V_TOTAL(4)
    ) dut (
        .clk(clk), .reset_n(reset_n), .keys(16'h0),
        .rgb(rgb), .de(de), .hs(hs), .vs(vs), .skip(skip), .frame_count(frame_count)
    );

    integer errors = 0;
    integer n = 0;
    integer min_x = 9999, max_x = 0, min_y = 9999, max_y = 0;
    integer flips_x = 0, flips_y = 0;
    reg last_dx = 1'b1, last_dy = 1'b1;

    always @(posedge clk) begin
        if (vs) begin
            n = n + 1;
            if (dut.box_x > 360 || dut.box_y > 192) begin
                errors = errors + 1;
                if (errors < 10) $display("ERROR frame %0d: box out of range (%0d,%0d)", n, dut.box_x, dut.box_y);
            end
            if (dut.box_x < min_x) min_x = dut.box_x;
            if (dut.box_x > max_x) max_x = dut.box_x;
            if (dut.box_y < min_y) min_y = dut.box_y;
            if (dut.box_y > max_y) max_y = dut.box_y;
            if (dut.box_dx != last_dx) flips_x = flips_x + 1;
            if (dut.box_dy != last_dy) flips_y = flips_y + 1;
            last_dx = dut.box_dx;
            last_dy = dut.box_dy;
        end
    end

    initial begin
        repeat (5) @(posedge clk);
        reset_n = 1'b1;
        repeat (32 * 2000) @(posedge clk);
        $display("frames=%0d x:[%0d..%0d] y:[%0d..%0d] flips x=%0d y=%0d", n, min_x, max_x, min_y, max_y, flips_x, flips_y);
        if (min_x != 0 || max_x != 360 || min_y != 0 || max_y != 192) errors = errors + 1;
        if (flips_x < 4 || flips_y < 4) errors = errors + 1;
        if (errors == 0) $display("PASS: box stays inside 384x216 and bounces off all four edges");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end

endmodule

`default_nettype wire
