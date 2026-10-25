// Simple dual-port RAM, one write port, one registered read port (infers M10K).
module periph_ram #(parameter AW = 9, parameter DW = 32) (
    input  wire          clk,
    input  wire          we,
    input  wire [AW-1:0] wa,
    input  wire [DW-1:0] wd,
    input  wire [AW-1:0] ra,
    output reg  [DW-1:0] rd
);
    reg [DW-1:0] mem [0:(1<<AW)-1];
    always @(posedge clk) begin
        if (we) mem[wa] <= wd;
        rd <= mem[ra];
    end
endmodule

// Synchronous FIFO on a RAM. rd_en pops; rd_data is valid the cycle after rd_en.
module periph_fifo #(parameter AW = 9, parameter DW = 32) (
    input  wire          clk,
    input  wire          rst,
    input  wire          wr_en,
    input  wire [DW-1:0] wr_data,
    input  wire          rd_en,
    output wire [DW-1:0] rd_data,
    output wire          empty,
    output wire          full,
    output reg  [AW:0]   count
);
    reg [AW-1:0] wp, rp;
    assign empty = count == 0;
    assign full  = count[AW];
    periph_ram #(.AW(AW), .DW(DW)) ram (.clk(clk), .we(wr_en && !full), .wa(wp), .wd(wr_data), .ra(rp), .rd(rd_data));
    wire do_w = wr_en && !full, do_r = rd_en && !empty;
    always @(posedge clk) begin
        if (rst) begin wp <= 0; rp <= 0; count <= 0; end
        else begin
            if (do_w) wp <= wp + 1'b1;
            if (do_r) rp <= rp + 1'b1;
            count <= count + do_w - do_r;
        end
    end
endmodule
