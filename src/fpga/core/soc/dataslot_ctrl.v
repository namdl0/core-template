//
// dataslot_ctrl.v - CPU access to APF data slots (UFO50 Pocket SoC, M3)
//
// MMIO window 0x8001_0000 (registers: docs/MEMORY_MAP.md section 3.2):
//   - target command 0x0180 "data slot read": the APF reads <length> bytes at
//     <offset> of slot <id> and writes them over the bridge to <addr> (SDRAM).
//   - DS_TABLE: read-only view of the APF data-slot size table (bridge 0xF8002000).
//
// Clock crossing: parameters are written in clk_sys and only change while idle;
// start/done/table requests cross as toggles (2-3 flop synchronisers).
// "done" is reported only after the bridge->SDRAM path has drained (bridge_idle),
// so the data is in SDRAM when the CPU sees it.
//
`default_nettype none

module dataslot_ctrl (
    input  wire         clk_sys,
    input  wire         rst_sys,
    input  wire [15:2]  wb_adr,
    input  wire [31:0]  wb_dat_w,
    input  wire         wb_we,
    input  wire         wb_stb,         // cyc & stb & window select
    output reg  [31:0]  wb_dat_r,
    output reg          wb_ack,
    input  wire         bridge_idle,
    output reg          done_pulse,
    input  wire         allcomplete,    // synchronised already

    input  wire         clk_74a,
    output reg          target_dataslot_read,
    output wire [15:0]  target_dataslot_id,
    output wire [31:0]  target_dataslot_slotoffset,
    output wire [31:0]  target_dataslot_bridgeaddr,
    output wire [31:0]  target_dataslot_length,
    input  wire         target_dataslot_ack,
    input  wire         target_dataslot_done,
    input  wire [2:0]   target_dataslot_err,
    output reg  [9:0]   datatable_addr,
    input  wire [31:0]  datatable_q
);

// ------------------------------------------------------------------ sys side
    reg [15:0] r_id;
    reg [31:0] r_off, r_addr, r_len;
    reg        busy, done, err;
    reg [2:0]  errcode;
    reg        start_t;
    reg        tbl_req_t;
    reg [5:0]  tbl_idx;
    reg        tbl_wait;
    reg        fin_pend;            // APF finished, waiting for the bridge path to drain

    // from 74a
    reg        fin_t_74, tbl_ack_t_74;
    reg [2:0]  err_74;
    reg [31:0] tbl_q_74;
    reg [2:0]  fin_s, tack_s;

    assign target_dataslot_id         = r_id;
    assign target_dataslot_slotoffset = r_off;
    assign target_dataslot_bridgeaddr = r_addr;
    assign target_dataslot_length     = r_len;

    wire [7:0] off = {wb_adr[7:2], 2'b00};
    wire       is_tbl = wb_adr[8];             // 0x100-0x1FC

always @(posedge clk_sys) begin
    fin_s  <= {fin_s[1:0], fin_t_74};
    tack_s <= {tack_s[1:0], tbl_ack_t_74};
    wb_ack     <= 1'b0;
    done_pulse <= 1'b0;

    if (rst_sys) begin
        busy      <= 1'b0;
        done      <= 1'b0;
        err       <= 1'b0;
        errcode   <= 3'd0;
        tbl_wait  <= 1'b0;
        fin_pend  <= 1'b0;
        r_id <= 16'd0; r_off <= 32'd0; r_addr <= 32'h1000_0000; r_len <= 32'd0;
    end else begin
        if (fin_s[2] ^ fin_s[1]) fin_pend <= 1'b1;
        if (fin_pend && bridge_idle) begin
            fin_pend   <= 1'b0;
            busy       <= 1'b0;
            done       <= 1'b1;
            errcode    <= err_74;               // stable since the toggle
            err        <= (err_74 != 3'd0);
            done_pulse <= 1'b1;
        end

        if (wb_stb && !wb_ack) begin
            if (is_tbl) begin
                if (!tbl_wait) begin
                    tbl_wait  <= 1'b1;
                    tbl_idx   <= wb_adr[7:2];
                    tbl_req_t <= ~tbl_req_t;
                end else if (tack_s[2] ^ tack_s[1]) begin
                    tbl_wait <= 1'b0;
                    wb_dat_r <= tbl_q_74;
                    wb_ack   <= 1'b1;
                end
            end else begin
                wb_ack <= 1'b1;
                if (wb_we) begin
                    if (!busy) case (off)
                    8'h00: r_id   <= wb_dat_w[15:0];
                    8'h04: r_off  <= wb_dat_w;
                    8'h08: r_addr <= wb_dat_w;
                    8'h0C: r_len  <= wb_dat_w;
                    8'h10: if (wb_dat_w[0]) begin
                               busy    <= 1'b1;
                               done    <= 1'b0;
                               err     <= 1'b0;
                               start_t <= ~start_t;
                           end
                    default: ;
                    endcase
                end else begin
                    case (off)
                    8'h00: wb_dat_r <= {16'd0, r_id};
                    8'h04: wb_dat_r <= r_off;
                    8'h08: wb_dat_r <= r_addr;
                    8'h0C: wb_dat_r <= r_len;
                    8'h14: wb_dat_r <= {15'd0, allcomplete, 5'd0, errcode, 5'd0, err, done, busy};
                    default: wb_dat_r <= 32'd0;
                    endcase
                end
            end
        end
    end
end

    initial begin start_t = 1'b0; tbl_req_t = 1'b0; end

// ------------------------------------------------------------------ 74a side
    reg [2:0] start_s, treq_s;
    reg [1:0] st;
    reg [2:0] tst;
    initial begin fin_t_74 = 1'b0; tbl_ack_t_74 = 1'b0; st = 2'd0; tst = 3'd0; target_dataslot_read = 1'b0; end

always @(posedge clk_74a) begin
    start_s <= {start_s[1:0], start_t};
    treq_s  <= {treq_s[1:0], tbl_req_t};

    case (st)
    2'd0: if (start_s[2] ^ start_s[1]) begin
        target_dataslot_read <= 1'b1;         // rising edge starts 0x0180
        st <= 2'd1;
    end
    2'd1: if (!target_dataslot_done) begin    // core_bridge_cmd cleared the previous done
        target_dataslot_read <= 1'b0;
        st <= 2'd2;
    end
    2'd2: if (target_dataslot_done) begin
        err_74   <= target_dataslot_err;
        fin_t_74 <= ~fin_t_74;
        st <= 2'd0;
    end
    default: st <= 2'd0;
    endcase

    // size table reads (port A of mf_datatable, 2 clock read latency)
    case (tst)
    3'd0: if (treq_s[2] ^ treq_s[1]) begin
        datatable_addr <= {4'd0, tbl_idx};    // stable while the request is pending
        tst <= 3'd1;
    end
    3'd1: tst <= 3'd2;                        // mf_datatable: registered address and output,
    3'd2: tst <= 3'd3;                        // data valid 2 clocks after the address;
    3'd3: tst <= 3'd4;                        // one spare clock
    3'd4: begin
        tbl_q_74     <= datatable_q;
        tbl_ack_t_74 <= ~tbl_ack_t_74;
        tst <= 3'd0;
    end
    default: tst <= 3'd0;
    endcase
end

endmodule

`default_nettype wire
