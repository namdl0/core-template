// Behavioural model of the SoC's SDRAM arbiter port as seen by one master
// (docs/MEMORY_MAP.md section 5): one command at a time, 1..64 beats (mem_cmd_len = beats - 1),
// write data pulled with mem_wready (the next beat must be on the bus the cycle after each pulse;
// pulses may be back to back), reads return mem_cmd_len+1 rvalid beats in order with no
// backpressure. mem_cmd_addr is a WORD address (bits 25:2 of the CPU address).
// Random timing: STALL_PCT withholds mem_cmd_ready, LAT = read latency / first write pull delay
// (at least 1 extra cycle, as the real arbiter's busy flag adds one), GAP_PCT = idle cycles
// between beats (the M4/M5 controllers move one 32-bit beat every 2 clocks at SDRAM_2X = 0).
module sdram_arb_model #(
    parameter MEMW      = 1 << 20,
    parameter LAT       = 8,
    parameter STALL_PCT = 0,
    parameter GAP_PCT   = 0,
    parameter SEED      = 1
) (
    input  wire        clk,
    input  wire        mem_cmd_valid,
    input  wire        mem_cmd_we,
    input  wire [25:2] mem_cmd_addr,
    input  wire [5:0]  mem_cmd_len,
    input  wire [31:0] mem_wdata,
    input  wire [3:0]  mem_wstrb,
    output reg         mem_cmd_ready,
    output reg         mem_wready,
    output reg  [31:0] mem_rdata,
    output reg         mem_rvalid
);
    reg [31:0] mem [0:MEMW-1];
    integer seed = SEED;
    localparam S_IDLE = 2'd0, S_WR = 2'd1, S_LAT = 2'd2, S_RD = 2'd3;
    reg [1:0]  st;
    reg        we_q;
    reg [23:2] addr; reg [5:0] left; reg [7:0] rem_lat;
    reg [11:0] row_q;
    initial begin mem_cmd_ready = 0; mem_wready = 0; mem_rvalid = 0; st = S_IDLE; end
    reg gap;
    always @(posedge clk) begin
        mem_wready <= 0; mem_rvalid <= 0;
        gap = ($unsigned($random(seed)) % 100) < GAP_PCT;
        case (st)
            S_IDLE: begin
                mem_cmd_ready <= (($unsigned($random(seed)) % 100) >= STALL_PCT);
                if (mem_cmd_valid && mem_cmd_ready) begin
                    // an access must stay inside one 2 KB SDRAM row
                    if ({mem_cmd_addr[25:11]} != {(mem_cmd_addr + mem_cmd_len) >> 9}) begin
                        $display("sdram_arb_model: ERROR access crosses a 2 KB row: addr %h len %0d", mem_cmd_addr, mem_cmd_len + 1);
                        $finish;
                    end
                    addr <= mem_cmd_addr[23:2]; left <= mem_cmd_len; we_q <= mem_cmd_we;
                    mem_cmd_ready <= 0; rem_lat <= 1 + ($unsigned($random(seed)) % (LAT + 1)); st <= S_LAT;
                end
            end
            S_LAT: begin
                if (rem_lat == 0) begin
                    st <= we_q ? S_WR : S_RD;
                    if (we_q) mem_wready <= 1;
                end else rem_lat <= rem_lat - 1'b1;
            end
            S_WR: begin
                if (mem_wready) begin
                    if (mem_wstrb[0]) mem[addr][7:0]   <= mem_wdata[7:0];
                    if (mem_wstrb[1]) mem[addr][15:8]  <= mem_wdata[15:8];
                    if (mem_wstrb[2]) mem[addr][23:16] <= mem_wdata[23:16];
                    if (mem_wstrb[3]) mem[addr][31:24] <= mem_wdata[31:24];
                    if (left == 0) st <= S_IDLE;
                    else begin addr <= addr + 1'b1; left <= left - 1'b1; mem_wready <= !gap; end
                end else mem_wready <= !gap;
            end
            S_RD: begin
                if (!gap) begin
                    mem_rvalid <= 1; mem_rdata <= mem[addr];
                    if (left == 0) st <= S_IDLE;
                    else begin addr <= addr + 1'b1; left <= left - 1'b1; end
                end
            end
            default: st <= S_IDLE;
        endcase
    end
endmodule
