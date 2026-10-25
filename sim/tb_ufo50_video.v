//
// tb_ufo50_video.v - self-checking testbench for src/fpga/core/ufo50_video.v
//
// Run (Icarus Verilog >= 11):
//   iverilog -g2005 -Wall -o sim/tb.vvp sim/tb_ufo50_video.v src/fpga/core/ufo50_video.v
//   vvp sim/tb.vvp
//   python3 tools/ppm_to_png.py sim/frame1.ppm   (optional, needs Pillow)
//
// Checks, per frame:
//   - VS period == H_TOTAL*V_TOTAL clocks, exactly one VS per frame
//   - HS period == H_TOTAL, V_TOTAL HS pulses per frame, HS never with VS or DE
//   - DE is one contiguous run of H_ACTIVE clocks on exactly V_ACTIVE lines
//   - RGB == 0 whenever DE is low, skip == 0 always
//   - pattern spot checks (border, red ring, bars) and box movement
// Frame 1 is dumped to sim/frame1.ppm, frame 3 (A held) to sim/frame3.ppm.
//
`timescale 1ns/1ps
`default_nettype none

module tb_ufo50_video;

    localparam H_ACTIVE = 384;
    localparam H_TOTAL  = 512;
    localparam V_ACTIVE = 216;
    localparam V_TOTAL  = 400;
    localparam FRAME    = H_TOTAL * V_TOTAL;

    reg         clk = 1'b0;
    reg         reset_n = 1'b0;
    reg [15:0]  keys = 16'h0;

    wire [23:0] rgb;
    wire        de, hs, vs, skip;
    wire [15:0] frame_count;

    // 12.288 MHz -> 81.380 ns period
    always #40.690 clk = ~clk;

    ufo50_video dut (
        .clk         ( clk ),
        .reset_n     ( reset_n ),
        .keys        ( keys ),
        .rgb         ( rgb ),
        .de          ( de ),
        .hs          ( hs ),
        .vs          ( vs ),
        .skip        ( skip ),
        .frame_count ( frame_count )
    );

    integer errors = 0;
    integer cyc = 0;

    // per-frame statistics
    integer frames_seen = 0;
    integer last_vs = -1;
    integer last_hs = -1;
    integer hs_in_frame = 0;
    integer de_lines = 0;
    integer de_pixels = 0;
    integer run = 0;
    integer px = 0, py = 0;          // position inside the DE window
    integer de_prev = 0;
    integer de_first_x = -1;         // clocks from HS to first DE on a line
    integer since_hs = 0;
    integer first_de_offset = -1;

    // box bounding box (orange or cyan pixels not on the border)
    integer bx0, by0, bx1, by1;
    integer prev_bx0 = -1, prev_by0 = -1;

    reg [23:0] fb [0:H_ACTIVE*V_ACTIVE-1];

    task fail(input [8*80-1:0] msg);
        begin
            errors = errors + 1;
            if (errors < 20) $display("ERROR @cyc %0d frame %0d: %0s", cyc, frames_seen, msg);
        end
    endtask

    task check_frame;
        integer i;
        begin
            if (hs_in_frame != V_TOTAL) begin
                fail("HS count per frame != V_TOTAL");
                $display("   hs_in_frame=%0d", hs_in_frame);
            end
            if (de_lines != V_ACTIVE) begin
                fail("DE line count != V_ACTIVE");
                $display("   de_lines=%0d", de_lines);
            end
            if (de_pixels != H_ACTIVE*V_ACTIVE) begin
                fail("DE pixel count != H_ACTIVE*V_ACTIVE");
                $display("   de_pixels=%0d", de_pixels);
            end
            // locate box
            bx0 = 9999; by0 = 9999; bx1 = -1; by1 = -1;
            for (i = 0; i < H_ACTIVE*V_ACTIVE; i = i + 1) begin
                if (fb[i] == 24'hFF8000 || fb[i] == 24'h00C0FF) begin
                    if (i % H_ACTIVE < bx0) bx0 = i % H_ACTIVE;
                    if (i % H_ACTIVE > bx1) bx1 = i % H_ACTIVE;
                    if (i / H_ACTIVE < by0) by0 = i / H_ACTIVE;
                    if (i / H_ACTIVE > by1) by1 = i / H_ACTIVE;
                end
            end
            // spot checks on the captured frame
            if (fb[0] !== 24'hFFFFFF)                                    fail("top-left pixel not white");
            if (fb[H_ACTIVE-1] !== 24'hFFFFFF)                           fail("top-right pixel not white");
            if (fb[(V_ACTIVE-1)*H_ACTIVE] !== 24'hFFFFFF)                fail("bottom-left pixel not white");
            if (fb[V_ACTIVE*H_ACTIVE-1] !== 24'hFFFFFF)                  fail("bottom-right pixel not white");
            if (fb[1*H_ACTIVE+1] !== 24'hFF0000)                         fail("(1,1) not red");
            if (fb[(V_ACTIVE-2)*H_ACTIVE + H_ACTIVE-2] !== 24'hFF0000)   fail("(382,214) not red");
            if (fb[100*H_ACTIVE + 2] !== 24'hFFFFFF && bx0 > 10)         fail("bar 0 not white");
            if (fb[100*H_ACTIVE + 360] !== 24'h000000 && bx1 < 330)      fail("bar 7 not black");

            $display("frame %0d: hs=%0d de_lines=%0d de_px=%0d first_de_after_hs=%0d box=(%0d,%0d)-(%0d,%0d)",
                     frames_seen, hs_in_frame, de_lines, de_pixels, first_de_offset, bx0, by0, bx1, by1);
            if (bx1 >= 0 && (bx1 - bx0 + 1 > 24 || by1 - by0 + 1 > 24)) fail("box larger than 24x24");
            if (prev_bx0 >= 0 && keys[5] == 1'b0 && bx0 == prev_bx0 && by0 == prev_by0) fail("box did not move");
            if (frames_seen >= 5 && (bx0 != prev_bx0 || by0 != prev_by0)) fail("box moved while B held");
            if (frames_seen == 3 && fb[by0*H_ACTIVE + bx0 + 2] !== 24'h00C0FF) fail("box not cyan with A held");
            if (frames_seen == 1 && fb[by0*H_ACTIVE + bx0 + 2] !== 24'hFF8000) fail("box not orange");
            prev_bx0 = bx0; prev_by0 = by0;
        end
    endtask

    task dump_ppm(input [8*32-1:0] fname);
        integer f, i;
        begin
            f = $fopen(fname, "wb");
            $fwrite(f, "P6\n%0d %0d\n255\n", H_ACTIVE, V_ACTIVE);
            for (i = 0; i < H_ACTIVE*V_ACTIVE; i = i + 1)
                $fwrite(f, "%c%c%c", fb[i][23:16], fb[i][15:8], fb[i][7:0]);
            $fclose(f);
        end
    endtask

    always @(posedge clk) begin
        cyc = cyc + 1;

        if (skip !== 1'b0) fail("skip != 0");
        if (!de && rgb !== 24'h0) fail("rgb nonzero outside DE");
        if (hs && vs) fail("HS and VS in the same cycle");
        if (hs && de) fail("HS during DE");

        // HS
        since_hs = since_hs + 1;
        if (hs) begin
            if (last_hs >= 0 && cyc - last_hs != H_TOTAL) fail("HS period != H_TOTAL");
            last_hs = cyc;
            hs_in_frame = hs_in_frame + 1;
            since_hs = 0;
        end

        // DE
        if (de) begin
            if (!de_prev) begin
                run = 0;
                px = 0;
                if (first_de_offset < 0) first_de_offset = since_hs;
                else if (since_hs != first_de_offset) fail("DE start moves relative to HS");
            end
            if (py < V_ACTIVE && px < H_ACTIVE) fb[py*H_ACTIVE + px] = rgb;
            px = px + 1;
            run = run + 1;
            de_pixels = de_pixels + 1;
        end else if (de_prev) begin
            if (run != H_ACTIVE) begin
                fail("DE run length != H_ACTIVE");
                $display("   run=%0d", run);
            end
            de_lines = de_lines + 1;
            py = py + 1;
        end
        de_prev = de;

        // VS: close previous frame
        if (vs) begin
            if (last_vs >= 0) begin
                if (cyc - last_vs != FRAME) begin
                    fail("VS period != H_TOTAL*V_TOTAL");
                    $display("   period=%0d", cyc - last_vs);
                end
                if (de) fail("VS during DE");
                frames_seen = frames_seen + 1;
                check_frame;
                if (frames_seen == 1) dump_ppm("sim/frame1.ppm");
                if (frames_seen == 3) dump_ppm("sim/frame3.ppm");
            end
            last_vs = cyc;
            hs_in_frame = 0;
            de_lines = 0;
            de_pixels = 0;
            py = 0;
        end
    end

    initial begin
        repeat (20) @(posedge clk);
        reset_n = 1'b1;

        // frames 1-2 normal; frame 3 with A held (cyan box); frames 4-5 with B held (frozen box)
        wait (frames_seen == 2);
        keys = 16'h0010;
        wait (frames_seen == 3);
        keys = 16'h0020;
        wait (frames_seen == 4);   // box state already updated at start of frame 4 before B synced
        wait (frames_seen == 6);

        $display("refresh = 12.288 MHz / %0d = %f Hz", FRAME, 12288000.0 / FRAME);
        if (errors == 0) $display("PASS: %0d frames checked", frames_seen);
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end

    // timeout
    initial begin
        #(81.380 * FRAME * 8);
        $display("FAIL: timeout");
        $finish;
    end

endmodule

`default_nettype wire
