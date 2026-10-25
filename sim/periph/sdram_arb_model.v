// Behavioural model of the SoC's SDRAM arbiter port as seen by one master
// (docs/MEMORY_MAP.md section 5): one outstanding command, <= 8 beats, write data pulled
// with mem_wready (one pulse per beat), reads return mem_len+1 rvalid pulses in order with
// no backpressure. mem_cmd_addr is a WORD address (bits 25:2 of the CPU address).
module sdram_arb_model #(
    parameter MEMW      = 1 << 20,
    parameter LAT       = 8,
    parameter STALL_PCT = 0,
    parameter SEED      = 1
) (
    input  wire        clk,
    input  wire        mem_cmd_valid,
    input  wire        mem_cmd_we,
    input  wire [25:2] mem_cmd_addr,
    input  wire [2:0]  mem_cmd_len,
    input  wire [31:0] mem_wdata,
    input  wire [3:0]  mem_wstrb,
    output reg         mem_cmd_ready,
    output reg         mem_wready,
    output reg  [31:0] mem_rdata,
    output reg         mem_rvalid
);
    reg [31:0] mem [0:MEMW-1];
    integer seed = SEED;
    localparam S_IDLE = 2'd0, S_WR = 2'd1, S_RD_LAT = 2'd2, S_RD = 2'd3;
    reg [1:0]  st;
    reg [23:2] addr; reg [2:0] left; reg [2:0] rem_lat;
    initial begin mem_cmd_ready = 0; mem_wready = 0; mem_rvalid = 0; end
    always @(posedge clk) begin
        mem_wready <= 0; mem_rvalid <= 0;
        case (st)
            S_IDLE: begin
                mem_cmd_ready <= (($unsigned($random(seed)) % 100) >= STALL_PCT);
                if (mem_cmd_valid && mem_cmd_ready) begin
                    addr <= mem_cmd_addr[23:2]; left <= mem_cmd_len;
                    if (mem_cmd_we) begin
                        mem_cmd_ready <= 0; mem_wready <= 1; st <= S_WR;
                    end else begin
                        mem_cmd_ready <= 0; rem_lat <= LAT[2:0]; st <= S_RD_LAT;
                    end
                end
            end
            S_WR: begin
                if (mem_wready) begin
                    if (mem_wstrb[0]) mem[addr][7:0]   <= mem_wdata[7:0];
                    if (mem_wstrb[1]) mem[addr][15:8]  <= mem_wdata[15:8];
                    if (mem_wstrb[2]) mem[addr][23:16] <= mem_wdata[23:16];
                    if (mem_wstrb[3]) mem[addr][31:24] <= mem_wdata[31:24];
                    if (left == 0) st <= S_IDLE;
                    else begin addr <= addr + 1'b1; left <= left - 1'b1; mem_wready <= 1; end
                end
            end
            S_RD_LAT: begin
                if (rem_lat == 0) st <= S_RD;
                else rem_lat <= rem_lat - 1'b1;
            end
            S_RD: begin
                mem_rvalid <= 1; mem_rdata <= mem[addr];
                if (left == 0) st <= S_IDLE;
                else begin addr <= addr + 1'b1; left <= left - 1'b1; end
            end
            default: st <= S_IDLE;
        endcase
    end
endmodule
