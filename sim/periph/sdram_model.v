// Behavioural memory for the peripherals' internal port (periph_mem_port.v semantics).
// Read data is captured when the request is accepted (so request order is honoured) and
// returned LAT cycles later, one beat per cycle, with optional random gaps; p_ready is
// randomly withheld (STALL_PCT). BEAT_CYC > 1 models a narrower SDRAM (16-bit: 2 cycles
// per 32-bit beat).
module sdram_model #(
    parameter MEMW      = 1 << 20,   // words
    parameter LAT       = 8,
    parameter STALL_PCT = 0,
    parameter GAP_PCT   = 0,
    parameter BEAT_CYC  = 1,
    parameter SEED      = 1
) (
    input  wire        clk,
    input  wire        p_valid,
    output reg         p_ready,
    input  wire [31:0] p_addr,
    input  wire        p_write,
    input  wire [8:0]  p_len,
    input  wire [31:0] p_wdata,
    input  wire [3:0]  p_be,
    output reg  [31:0] p_rdata,
    output reg         p_rvalid
);
    reg [31:0] mem [0:MEMW-1];
    // return queue
    reg [31:0] qd [0:8191]; reg [63:0] qt [0:8191];
    integer qw = 0, qr = 0, wbeat = 0, seed = SEED, k, beatc = 0;
    reg [63:0] now = 0, last_t = 0;
    reg [31:0] wa;
    initial begin p_ready = 0; p_rvalid = 0; end
    always @(posedge clk) begin
        now <= now + 1;
        // returns
        p_rvalid <= 0;
        if (qr != qw && qt[qr % 8192] <= now && ($unsigned($random(seed)) % 100) >= GAP_PCT) begin
            p_rvalid <= 1; p_rdata <= qd[qr % 8192]; qr = qr + 1;
        end
        // accept
        if (p_valid && p_ready) begin
            if (p_write) begin
                wa = (p_addr >> 2) + wbeat;
                if (p_be[0]) mem[wa][7:0]   <= p_wdata[7:0];
                if (p_be[1]) mem[wa][15:8]  <= p_wdata[15:8];
                if (p_be[2]) mem[wa][23:16] <= p_wdata[23:16];
                if (p_be[3]) mem[wa][31:24] <= p_wdata[31:24];
                wbeat = (wbeat + 1 == p_len) ? 0 : wbeat + 1;
            end else begin
                if (last_t < now + LAT) last_t = now + LAT;
                for (k = 0; k < p_len; k = k + 1) begin
                    qd[qw % 8192] = mem[(p_addr >> 2) + k];
                    last_t = last_t + BEAT_CYC; qt[qw % 8192] = last_t;
                    qw = qw + 1;
                end
            end
        end
        // ready for next cycle; a write beat costs BEAT_CYC cycles
        if (p_valid && p_ready && p_write && BEAT_CYC > 1) begin beatc = BEAT_CYC - 1; p_ready <= 0; end
        else if (beatc > 0) begin beatc = beatc - 1; p_ready <= 0; end
        else p_ready <= (($unsigned($random(seed)) % 100) >= STALL_PCT) && (qw - qr < 7000);
    end
endmodule
