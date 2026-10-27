// UFO 50 blitter engine: executes the 8-word display-list commands of docs/BLITTER.md.
//
// Row pipeline, three concurrent stages per command:
//   fetch   : row f -> source index bytes into srcbuf[f%2], destination pixels into dstbuf[f%2]
//             (only when the result depends on them); read bursts may be outstanding.
//   compute : row c -> 1 pixel/clock through palette, tint/fog, alpha, blend into outbuf[c%2]
//             with a per-pixel write mask (8-stage pipeline, rows stream back to back).
//   write   : row w -> masked write bursts over the written span.
// Memory port: the SoC's SDRAM master port directly (docs/MEMORY_MAP.md section 5: one command
// at a time, <= 64 beats inside one 2 KB SDRAM row, write data pulled with s_wready). Every
// access is cut at the 64-beat limit and at 2 KB row boundaries only, and a write command is
// presented as soon as its first beats are in the 3-entry skid buffer (the row is already in
// outbuf, so the data keeps up with any wready rate), so the bus never waits for a staging copy.
module blit_engine #(
    parameter MAX_BURST = 64            // beats (32-bit) per SDRAM access, <= 64
) (
    input  wire        clk,
    input  wire        rst,
    // command FIFO (data valid the cycle after cf_rd)
    input  wire        cf_empty,
    output wire        cf_rd,
    input  wire [31:0] cf_data,
    input  wire        pal_flush,       // invalidate the palette cache
    // status
    output wire        busy,
    output reg  [31:0] fence,
    output reg         fence_irq,       // 1-cycle pulse
    output reg  [31:0] perf_busy,
    output reg  [31:0] perf_pixels,
    output reg  [31:0] perf_memwait,
    // SDRAM master port (docs/MEMORY_MAP.md section 5)
    output reg         s_cmd_valid,
    output reg         s_cmd_we,
    output reg  [25:2] s_cmd_addr,
    output reg  [5:0]  s_cmd_len,      // beats - 1
    output wire [31:0] s_wdata,
    output wire [3:0]  s_wstrb,
    input  wire        s_cmd_ready,
    input  wire        s_wready,
    input  wire [31:0] s_rdata,
    input  wire        s_rvalid
);
    wire [31:0] m_rdata = s_rdata;
    wire        m_rvalid = s_rvalid;
    localparam OP_BLIT = 4'd0, OP_FILL = 4'd1, OP_CLEAR = 4'd2, OP_MAP = 4'd3,
               OP_SETDST = 4'd4, OP_SETTEX = 4'd5, OP_FENCE = 4'd6;
    localparam K_SRC = 3'd0, K_DST = 3'd1, K_PAL = 3'd2, K_MX = 3'd3, K_MY = 3'd4;

    // ------------------------------------------------------------------ command registers
    reg [31:0] cw [0:7];
    reg  [3:0] op;
    reg        flipx, flipy, fog;
    reg  [1:0] blend;
    reg [15:0] dx, dy, W, H, sx, sy;
    reg [23:0] colour; reg [31:0] clear_col;
    reg  [7:0] a255; reg alt1; reg [15:0] a16;
    reg [31:0] dst_base, tex_base; reg [15:0] dst_stride, tex_stride;
    reg [31:0] pal_tag [0:3]; reg [3:0] pal_valid, pal_partial;
    reg  [1:0] pal_cur, pal_rr;
    reg        needs_dst;           // the command may read the destination
    reg        dst_scan;            // ... only for rows whose source texels include a translucent one
    // per cached palette: which of the 256 entries are translucent (0 < alpha < 255), kept in partram
    // (4 palettes x 8 words x 32 bits); part_cur = the current palette's, used to scan each fetched
    // source row (see the fetch stage). Filled while a palette loads, copied back on a cache hit.
    reg [255:0] part_cur; reg [31:0] pacc; reg [3:0] pc_i;
    reg         pt_we; reg [4:0] pt_wa; reg [31:0] pt_wd; wire [4:0] pt_ra; wire [31:0] pt_rd;
    periph_ram #(.AW(5), .DW(32)) partram (.clk(clk), .we(pt_we), .wa(pt_wa), .wd(pt_wd), .ra(pt_ra), .rd(pt_rd));
    reg [11:0] mxmin, mxmax; reg mx_any;

    // ------------------------------------------------------------------ main FSM
    localparam M_IDLE = 4'd0, M_LOAD = 4'd1, M_DEC = 4'd2, M_PAL = 4'd3, M_WAIT = 4'd4, M_MX = 4'd5,
               M_MXW = 4'd6, M_MY = 4'd7, M_MYW = 4'd8, M_INIT = 4'd9, M_INIT2 = 4'd10, M_ROWS = 4'd11,
               M_PCPY = 4'd12;
    reg [3:0] ms;
    assign pt_ra = {pal_cur, pc_i[2:0]};
    reg [3:0] ld_req, ld_got;   // words popped / captured
    reg       cf_rd_d;
    assign cf_rd = (ms == M_LOAD) && !cf_empty && ld_req != 4'd8;
    // CLEAR coalescing: a CLEAR is held back (cl_pend) until the next command arrives; if that is a
    // CLEAR of the same rectangle on the same surface (nothing in between), the first one is
    // dropped (its pixels would all be overwritten). Anything else, or 256 idle cycles with an empty
    // FIFO, executes it first; cl_replay then re-decodes the command that is still in cw[].
    reg        cl_pend, cl_replay; reg [31:0] cl_w1, cl_w2, cl_col; reg [7:0] cl_hold;
    assign busy = (ms != M_IDLE) || !cf_empty || cl_pend;

    // job interface to the read requester
    reg        job_valid; reg [2:0] job_kind; reg job_slot; reg [31:0] job_addr; reg [10:0] job_nw;
    wire       job_ready;
    reg [31:0] issued_total, returned_total;

    // row counters
    reg [15:0] f_row, fd_row, c_row, comp, w_row;
    reg [31:0] fdst_addr, w_addr;
    reg [31:0] prod_init;

    wire rows_on = (ms == M_ROWS);

    // ------------------------------------------------------------------ RAMs
    reg [31:0] m_rdata_q;
    // srcbuf / dstbuf: 2 slots x 512 words
    reg        sb_we; reg [9:0] sb_wa; wire [9:0] sb_ra; wire [31:0] sb_rd;
    reg        db_we; reg [9:0] db_wa; wire [9:0] db_ra; wire [31:0] db_rd;
    periph_ram #(.AW(10), .DW(32)) srcbuf (.clk(clk), .we(sb_we), .wa(sb_wa), .wd(m_rdata_q), .ra(sb_ra), .rd(sb_rd));
    periph_ram #(.AW(10), .DW(32)) dstbuf (.clk(clk), .we(db_we), .wa(db_wa), .wd(m_rdata_q), .ra(db_ra), .rd(db_rd));
    // palettes: 4 x 256
    reg        pl_we; reg [9:0] pl_wa; wire [9:0] pl_ra; wire [31:0] pl_rd;
    periph_ram #(.AW(10), .DW(32)) palram (.clk(clk), .we(pl_we), .wa(pl_wa), .wd(m_rdata_q), .ra(pl_ra), .rd(pl_rd));
    // map tables: {invalid, value[11:0]}
    reg        mx_we; reg [8:0] mx_wa; wire [8:0] mx_ra; wire [12:0] mx_rd;
    reg        my_we; reg [9:0] my_wa; wire [9:0] my_ra; wire [12:0] my_rd;
    reg [12:0] tbl_wd;
    periph_ram #(.AW(9),  .DW(13)) mapx (.clk(clk), .we(mx_we), .wa(mx_wa), .wd(tbl_wd), .ra(mx_ra), .rd(mx_rd));
    periph_ram #(.AW(10), .DW(13)) mapy (.clk(clk), .we(my_we), .wa(my_wa), .wd(tbl_wd), .ra(my_ra), .rd(my_rd));
    // outbuf: 2 slots x 512 x {mask, pixel}
    reg        ob_we; reg [9:0] ob_wa; reg [32:0] ob_wd; wire [9:0] ob_ra; wire [32:0] ob_rd;
    periph_ram #(.AW(10), .DW(33)) outbuf (.clk(clk), .we(ob_we), .wa(ob_wa), .wd(ob_wd), .ra(ob_ra), .rd(ob_rd));

    // ------------------------------------------------------------------ read return path
    // tag FIFO: {kind[2:0], slot, idx[9:0], n[8:0]}
    reg [22:0] tagq [0:31]; reg [4:0] tq_wp, tq_rp; reg [5:0] tq_cnt;
    wire       tq_full = tq_cnt >= 6'd31;
    wire [22:0] tq_head = tagq[tq_rp];
    wire [9:0]  rt_sum = tq_head[18:9] + rt_off;
    reg [9:0]  rt_off;
    reg        tq_push; reg [22:0] tq_in;
    always @(posedge clk) begin
        sb_we <= 0; db_we <= 0; pl_we <= 0; mx_we <= 0; my_we <= 0;
        m_rdata_q <= m_rdata;
        if (rst) begin
            returned_total <= 0;
        end else if (m_rvalid) begin
            // head tag describes this beat; index = tag.idx + beats already received for it
            returned_total <= returned_total + 1'b1;
            case (tq_head[22:20])
                K_SRC: begin sb_we <= 1; sb_wa <= {tq_head[19], rt_sum[8:0]}; end
                K_DST: begin db_we <= 1; db_wa <= {tq_head[19], rt_sum[8:0]}; end
                K_PAL: begin pl_we <= 1; pl_wa <= {pal_cur, rt_sum[7:0]}; end
                K_MX:  begin mx_we <= 1; mx_wa <= rt_sum[8:0]; end
                default: begin my_we <= 1; my_wa <= rt_sum; end
            endcase
            tbl_wd <= {m_rdata[31] | (m_rdata[30:12] != 0), m_rdata[11:0]};
        end
    end
    // beats received for the head tag
    wire rt_last = m_rvalid && (rt_off + 1'b1 == {1'b0, tq_head[8:0]});
    always @(posedge clk) begin
        if (rst) begin rt_off <= 0; tq_rp <= 0; end
        else if (m_rvalid) begin
            if (rt_last) begin rt_off <= 0; tq_rp <= tq_rp + 1'b1; end
            else rt_off <= rt_off + 1'b1;
        end
    end
    always @(posedge clk) begin
        if (rst) begin tq_wp <= 0; tq_cnt <= 0; end
        else begin
            if (tq_push) begin tagq[tq_wp] <= tq_in; tq_wp <= tq_wp + 1'b1; end
            tq_cnt <= tq_cnt + tq_push - rt_last;
        end
    end
    // map-x min/max and palette translucency while loading (one cycle after the beat)
    reg        mxl_v; reg [2:0] rtk_d; reg rts_d; reg [7:0] rti_d;
    always @(posedge clk) begin
        rtk_d <= tq_head[22:20]; rts_d <= tq_head[19]; rti_d <= rt_sum[7:0];
        mxl_v <= m_rvalid;
    end
    // source-row scan: does any byte of this beat index a translucent palette entry?
    wire       scan_hit = part_cur[m_rdata_q[7:0]] | part_cur[m_rdata_q[15:8]] |
                          part_cur[m_rdata_q[23:16]] | part_cur[m_rdata_q[31:24]];
    reg  [1:0] s_part;              // per source slot: the row's fetched texels include a translucent one
    reg  [1:0] s_dst;               // per slot: the destination row was fetched

    // ------------------------------------------------------------------ read requester
    localparam R_IDLE = 2'd0, R_REQ = 2'd1, R_WAIT = 2'd2;
    reg [1:0]  rs;
    reg [2:0]  rq_kind; reg rq_slot; reg [31:0] rq_addr; reg [10:0] rq_rem; reg [9:0] rq_idx;
    // beats to the end of the 2 KB SDRAM row, the access limit, and what is left
    wire [9:0] rq_room = 10'd512 - {1'b0, rq_addr[10:2]};
    wire [8:0] rq_cap  = (rq_room < MAX_BURST) ? rq_room[8:0] : MAX_BURST[8:0];
    wire [8:0] rq_len  = (rq_rem > {2'b0, rq_cap}) ? rq_cap : rq_rem[8:0];
    reg        rd_req; wire rd_ack;
    assign job_ready = (rs == R_IDLE);
    always @(posedge clk) begin
        tq_push <= 0;
        if (rst) begin rs <= R_IDLE; rd_req <= 0; end
        else case (rs)
            R_IDLE: if (job_valid) begin
                rq_kind <= job_kind; rq_slot <= job_slot; rq_addr <= {job_addr[31:2], 2'b00};
                rq_rem <= job_nw; rq_idx <= 0; rs <= R_REQ;
            end
            R_REQ: if (!tq_full && !tq_push) begin rd_req <= 1; rs <= R_WAIT; end
            R_WAIT: if (rd_ack) begin
                rd_req <= 0;
                tq_push <= 1; tq_in <= {rq_kind, rq_slot, rq_idx, rq_len};
                rq_idx <= rq_idx + rq_len; rq_addr <= rq_addr + {rq_len, 2'b00}; rq_rem <= rq_rem - rq_len;
                rs <= (rq_rem == {2'b00, rq_len}) ? R_IDLE : R_REQ;
            end
            default: rs <= R_IDLE;
        endcase
    end

    // ------------------------------------------------------------------ port arbiter + writer
    // P_WC/P_RC: command presented; P_WB: write beats being pulled (s_wready).
    localparam P_IDLE = 2'd0, P_RC = 2'd1, P_WC = 2'd2, P_WB = 2'd3;
    reg [1:0] ps;
    reg       wr_req; reg [31:0] wb_addr; reg [8:0] wb_len; reg [8:0] wb_left;
    // write skid FIFO (4 entries, at most 3 used) fed from outbuf, head = current beat
    reg [32:0] sk [0:3]; reg [1:0] sk_wp, sk_rp; reg [2:0] sk_cnt; reg ob_inflight;
    wire       sk_pop = s_wready;
    assign s_wdata = sk[sk_rp][31:0];
    assign s_wstrb = {4{sk[sk_rp][32]}};
    wire       wr_go  = (ps == P_IDLE) && wr_req && sk_cnt != 0;
    wire       rd_go  = (ps == P_IDLE) && !wr_go && rd_req && rs == R_WAIT;
    assign rd_ack  = (ps == P_RC) && s_cmd_ready;
    wire wr_burst_done = sk_pop && wb_left == 9'd1;
    always @(posedge clk) begin
        if (rst) begin ps <= P_IDLE; s_cmd_valid <= 0; end
        else case (ps)
            P_IDLE: if (wr_go) begin
                    s_cmd_valid <= 1; s_cmd_we <= 1; s_cmd_addr <= wb_addr[25:2]; s_cmd_len <= wb_len[5:0] - 1'b1; ps <= P_WC;
                end else if (rd_go) begin
                    s_cmd_valid <= 1; s_cmd_we <= 0; s_cmd_addr <= rq_addr[25:2]; s_cmd_len <= rq_len[5:0] - 1'b1; ps <= P_RC;
                end
            P_RC: if (s_cmd_ready) begin s_cmd_valid <= 0; ps <= P_IDLE; end
            P_WC: if (s_cmd_ready) begin s_cmd_valid <= 0; ps <= P_WB; end
            P_WB: if (wr_burst_done) ps <= P_IDLE;
            default: ps <= P_IDLE;
        endcase
    end

    // ------------------------------------------------------------------ fetch stage
    localparam F_IDLE = 4'd0, F_A = 4'd1, F_B = 4'd2, F_C = 4'd3, F_D = 4'd4, F_E = 4'd5, F_W = 4'd6,
               F_S = 4'd7, F_S2 = 4'd8;
    reg [3:0]  fs;
    reg [31:0] smark;
    reg [15:0] f_srow; reg f_skip; reg [31:0] f_prod; reg [31:0] f_saddr; reg [10:0] f_nw;
    reg [31:0] mark [0:1]; reg [1:0] s_boff [0:1]; reg [1:0] s_skip;
    reg [15:0] f_issued;
    assign my_ra = f_row[9:0];
    wire is_map = (op == OP_MAP);
    wire has_src = (op == OP_BLIT) || is_map;
    wire [11:0] span_bytes = is_map ? (mxmax - mxmin + 1'b1) : W[11:0];

    // ------------------------------------------------------------------ compute stage
    reg [15:0] ci; reg c_run; reg c_slot;
    wire c_can = rows_on && !c_run && c_row < fd_row && c_row < w_row + 2'd2 && c_row < H;
    // P0 -> RAM addresses
    assign mx_ra = ci[8:0];
    assign db_ra = {c_slot, ci[8:0]};
    // pipeline registers
    reg        p1_v, p1_last, p1_nop, p1_slot; reg [9:0] p1_i;
    reg        p2_v, p2_last, p2_ok, p2_slot; reg [9:0] p2_i; reg [1:0] p2_bs; reg [31:0] p2_dst;
    reg        p3_v, p3_last, p3_ok, p3_slot; reg [9:0] p3_i; reg [31:0] p3_dst;
    reg        p4_v, p4_last, p4_ok, p4_slot; reg [9:0] p4_i; reg [31:0] p4_dst; reg [7:0] p4_ta;
    reg [15:0] p4_tr, p4_tg, p4_tb; reg [23:0] p4_fogc;
    reg        p5_v, p5_last, p5_ok, p5_slot; reg [9:0] p5_i; reg [31:0] p5_dst; reg [7:0] p5_sa;
    reg  [7:0] p5_r, p5_g, p5_b;
    reg        p6_v, p6_last, p6_ok, p6_slot; reg [9:0] p6_i; reg [31:0] p6_dst; reg [7:0] p6_sa;
    reg [16:0] p6_mr, p6_mg, p6_mb, p6_ma;  // products/sums
    reg        p7_v, p7_last, p7_mask, p7_slot; reg [9:0] p7_i; reg [31:0] p7_px;

    function [7:0] div255; input [16:0] x; reg [16:0] t; begin t = x + 17'd1 + {8'd0, x[16:8]}; div255 = t[15:8]; end endfunction

    // P1: source byte index
    wire [11:0] p1_off = is_map ? (mx_rd[11:0] - mxmin) : (flipx ? (W[11:0] - 12'd1 - {2'b0, p1_i}) : {2'b0, p1_i});
    wire [11:0] p1_bi  = {10'd0, s_boff[p1_slot]} + p1_off;
    wire        p1_ok  = !p1_nop && !(is_map && mx_rd[12]);
    assign sb_ra = {p1_slot, p1_bi[10:2]};
    // P2: palette address
    wire [7:0] p2_idx = p2_bs == 2'd0 ? sb_rd[7:0] : p2_bs == 2'd1 ? sb_rd[15:8] : p2_bs == 2'd2 ? sb_rd[23:16] : sb_rd[31:24];
    assign pl_ra = {pal_cur, p2_idx};
    // P3: texel
    wire [31:0] p3_tex = (op == OP_FILL || op == OP_CLEAR) ? {8'hFF, colour} : pl_rd;
    // P4: tint result and source alpha
    wire        fogx = fog && has_src;
    wire [23:0] tcol = has_src ? colour : 24'hFFFFFF;
    wire [7:0]  p4_r = fogx ? colour[7:0]   : div255({1'b0, p4_tr});
    wire [7:0]  p4_g = fogx ? colour[15:8]  : div255({1'b0, p4_tg});
    wire [7:0]  p4_b = fogx ? colour[23:16] : div255({1'b0, p4_tb});
    wire [24:0] p4_am = p4_ta * a16 + 25'h8000;
    wire [7:0]  p4_sa = !alt1 ? p4_ta : (p4_ta == 8'd255 ? a255 : p4_am[23:16]);
    // P6: blend
    wire [7:0] dr6 = p6_dst[7:0], dg6 = p6_dst[15:8], db6 = p6_dst[23:16], da6 = p6_dst[31:24];
    wire [7:0] q_r = div255(p6_mr), q_g = div255(p6_mg), q_b = div255(p6_mb), q_a = div255(p6_ma);
    wire [8:0] add_r = dr6 + q_r, add_g = dg6 + q_g, add_b = db6 + q_b;
    wire [8:0] sub_r = {1'b0, dr6} - q_r, sub_g = {1'b0, dg6} - q_g, sub_b = {1'b0, db6} - q_b;
    reg  [31:0] p6_px;
    always @(*) begin
        if (op == OP_CLEAR) p6_px = clear_col;
        else if (blend == 2'd1)
            p6_px = {(p6_sa > da6 ? p6_sa : da6), add_b[8] ? 8'hFF : add_b[7:0], add_g[8] ? 8'hFF : add_g[7:0], add_r[8] ? 8'hFF : add_r[7:0]};
        else if (blend == 2'd3)
            p6_px = {da6, sub_b[8] ? 8'h00 : sub_b[7:0], sub_g[8] ? 8'h00 : sub_g[7:0], sub_r[8] ? 8'h00 : sub_r[7:0]};
        else
            p6_px = {p6_sa + q_a, q_b, q_g, q_r};
    end
    wire p6_mask = p6_ok && (op == OP_CLEAR || p6_sa != 8'd0);
    wire normal = !(blend == 2'd1 || blend == 2'd3);

    always @(posedge clk) begin
        ob_we <= 0;
        if (rst || !rows_on) begin
            p1_v <= 0; p2_v <= 0; p3_v <= 0; p4_v <= 0; p5_v <= 0; p6_v <= 0; p7_v <= 0; c_run <= 0; c_row <= 0;
        end else begin
            // P0 issue
            p1_v <= 0;
            if (c_run) begin
                p1_v <= 1; p1_i <= ci[9:0]; p1_slot <= c_slot;
                p1_nop <= s_skip[c_slot];
                p1_last <= s_skip[c_slot] || (ci == W - 1'b1);
                if (s_skip[c_slot] || ci == W - 1'b1) c_run <= 0;
                ci <= ci + 1'b1;
            end else if (c_can) begin
                c_run <= 1; ci <= 0; c_slot <= c_row[0];
                c_row <= c_row + 1'b1;
            end
            // P1 -> P2
            p2_v <= p1_v; p2_last <= p1_last; p2_slot <= p1_slot; p2_i <= p1_i;
            p2_ok <= p1_ok; p2_bs <= p1_bi[1:0]; p2_dst <= s_dst[p1_slot] ? db_rd : 32'd0;
            // P2 -> P3
            p3_v <= p2_v; p3_last <= p2_last; p3_slot <= p2_slot; p3_i <= p2_i; p3_ok <= p2_ok; p3_dst <= p2_dst;
            // P3 -> P4
            p4_v <= p3_v; p4_last <= p3_last; p4_slot <= p3_slot; p4_i <= p3_i; p4_ok <= p3_ok; p4_dst <= p3_dst;
            p4_ta <= p3_tex[31:24];
            p4_tr <= p3_tex[7:0] * tcol[7:0]; p4_tg <= p3_tex[15:8] * tcol[15:8]; p4_tb <= p3_tex[23:16] * tcol[23:16];
            // P4 -> P5
            p5_v <= p4_v; p5_last <= p4_last; p5_slot <= p4_slot; p5_i <= p4_i; p5_dst <= p4_dst;
            p5_ok <= p4_ok; p5_sa <= p4_sa; p5_r <= p4_r; p5_g <= p4_g; p5_b <= p4_b;
            // P5 -> P6: products
            p6_v <= p5_v; p6_last <= p5_last; p6_slot <= p5_slot; p6_i <= p5_i; p6_dst <= p5_dst; p6_ok <= p5_ok; p6_sa <= p5_sa;
            if (normal) begin
                p6_mr <= p5_r * p5_sa + p5_dst[7:0]   * (8'd255 - p5_sa);
                p6_mg <= p5_g * p5_sa + p5_dst[15:8]  * (8'd255 - p5_sa);
                p6_mb <= p5_b * p5_sa + p5_dst[23:16] * (8'd255 - p5_sa);
            end else begin
                p6_mr <= p5_r * p5_sa; p6_mg <= p5_g * p5_sa; p6_mb <= p5_b * p5_sa;
            end
            p6_ma <= p5_dst[31:24] * (8'd255 - p5_sa);
            // P6 -> P7
            p7_v <= p6_v; p7_last <= p6_last; p7_slot <= p6_slot; p7_i <= p6_i;
            p7_mask <= p6_mask; p7_px <= p6_px;
            // P7: out buffer
            if (p7_v) begin
                ob_we <= 1; ob_wa <= {p7_slot, p7_i[8:0]}; ob_wd <= {p7_mask, p7_px};
            end
        end
    end
    // ------------------------------------------------------------------ write segments
    // Each computed row's written pixels are cut into segments wherever SEG_GAP or more pixels in a
    // row are not written (transparent texels, BLIT_MAP skips): a gap costs 2 clocks per pixel on the
    // 16-bit SDRAM inside a burst, a new access ~8. segram: 2 slots x 256 x {start, end}.
    localparam SEG_GAP = 10'd5;
    reg        sg_we; reg [8:0] sg_wa; reg [17:0] sg_wd; reg [8:0] sg_ra; wire [17:0] sg_rd;
    periph_ram #(.AW(9), .DW(18)) segram (.clk(clk), .we(sg_we), .wa(sg_wa), .wd(sg_wd), .ra(sg_ra), .rd(sg_rd));
    reg  [8:0] seg_n0, seg_n1;              // segments of the row in slot 0 / 1
    reg        so_v; reg [9:0] so_s, so_l;  // open segment of the row being computed
    reg        sq_v; reg sq_slot; reg [17:0] sq_wd;   // second segment closed at a row's last pixel
    reg  [1:0] comp_d;                      // a row counts as computed 2 cycles after its last pixel
    wire       sp_split = p7_mask && so_v && (p7_i - so_l > SEG_GAP);
    wire       sp_open  = so_v || p7_mask;
    wire [9:0] sp_s     = (p7_mask && (!so_v || sp_split)) ? p7_i : so_s;
    wire [9:0] sp_l     = p7_mask ? p7_i : so_l;
    always @(posedge clk) begin
        sg_we <= 0;
        if (rst || !rows_on) begin seg_n0 <= 0; seg_n1 <= 0; comp <= 0; so_v <= 0; sq_v <= 0; comp_d <= 0; end
        else begin
            if (c_can) begin if (c_row[0]) seg_n1 <= 0; else seg_n0 <= 0; end
            comp_d <= {comp_d[0], p7_v && p7_last};
            if (comp_d[1]) comp <= comp + 1'b1;
            if (sq_v) begin   // the queued close (never two in a row: a new row's first pixel closes nothing)
                sg_we <= 1; sg_wa <= {sq_slot, sq_slot ? seg_n1[7:0] : seg_n0[7:0]}; sg_wd <= sq_wd;
                if (sq_slot) seg_n1 <= seg_n1 + 1'b1; else seg_n0 <= seg_n0 + 1'b1;
                sq_v <= 0;
            end
            if (p7_v) begin
                if (sp_split) begin
                    sg_we <= 1; sg_wa <= {p7_slot, p7_slot ? seg_n1[7:0] : seg_n0[7:0]}; sg_wd <= {so_s[8:0], so_l[8:0]};
                    if (p7_slot) seg_n1 <= seg_n1 + 1'b1; else seg_n0 <= seg_n0 + 1'b1;
                end
                if (p7_last) begin
                    so_v <= 0;
                    if (sp_open) begin
                        if (sp_split) begin sq_v <= 1; sq_slot <= p7_slot; sq_wd <= {sp_s[8:0], sp_l[8:0]}; end
                        else begin
                            sg_we <= 1; sg_wa <= {p7_slot, p7_slot ? seg_n1[7:0] : seg_n0[7:0]}; sg_wd <= {sp_s[8:0], sp_l[8:0]};
                            if (p7_slot) seg_n1 <= seg_n1 + 1'b1; else seg_n0 <= seg_n0 + 1'b1;
                        end
                    end
                end else begin
                    so_v <= sp_open; so_s <= sp_s; so_l <= sp_l;
                end
            end
        end
    end

    // ------------------------------------------------------------------ write stage
    localparam W_IDLE = 3'd0, W_SET = 3'd1, W_BURST = 3'd2, W_SEGW = 3'd3, W_SEG = 3'd4;
    reg [2:0]  ws;
    reg [9:0]  w_rdi, w_end; reg [9:0] w_rem;
    reg        w_slot; reg [31:0] w_baddr; reg [8:0] w_seg, w_nseg;
    wire       w_ready_row = rows_on && w_row < comp;
    wire [8:0] w_rown = w_row[0] ? seg_n1 : seg_n0;
    // keep the skid topped up to 3 beats, counting the pop of this cycle (sustains 1 beat/clock)
    wire       ob_rd_en = (ws == W_SET || ws == W_BURST) && (w_rdi <= w_end) && ({1'b0, sk_cnt} + ob_inflight < 4'd3 + sk_pop);
    // next access: up to MAX_BURST beats, never past the 2 KB SDRAM row
    wire [9:0] w_room = 10'd512 - {1'b0, w_baddr[10:2]};
    wire [9:0] w_cap  = (w_room < MAX_BURST) ? w_room : MAX_BURST;
    assign ob_ra = {w_slot, w_rdi[8:0]};
    always @(posedge clk) begin
        if (rst || !rows_on) begin
            ws <= W_IDLE; wr_req <= 0; sk_cnt <= 0; sk_wp <= 0; sk_rp <= 0; ob_inflight <= 0; w_row <= 0;
            w_addr <= dst_base + prod_init + {dx, 2'b00};
        end else begin
            ob_inflight <= ob_rd_en;
            if (ob_inflight) begin sk[sk_wp] <= ob_rd; sk_wp <= sk_wp + 1'b1; end
            if (sk_pop) sk_rp <= sk_rp + 1'b1;
            sk_cnt <= sk_cnt + ob_inflight - sk_pop;
            if (ob_rd_en) w_rdi <= w_rdi + 1'b1;
            case (ws)
                W_IDLE: if (w_ready_row) begin
                    if (w_rown == 0) begin w_row <= w_row + 1'b1; w_addr <= w_addr + dst_stride; end
                    else begin
                        w_slot <= w_row[0]; w_seg <= 0; w_nseg <= w_rown;
                        sg_ra <= {w_row[0], 8'd0};
                        ws <= W_SEGW;
                    end
                end
                W_SEGW: ws <= W_SEG;            // segram read latency
                W_SEG: begin
                    w_rdi <= {1'b0, sg_rd[17:9]}; w_end <= {1'b0, sg_rd[8:0]};
                    w_rem <= {1'b0, sg_rd[8:0]} - {1'b0, sg_rd[17:9]} + 1'b1;
                    w_baddr <= w_addr + {sg_rd[17:9], 2'b00};
                    ws <= W_SET;
                end
                W_SET: begin
                    wb_addr <= w_baddr;
                    wb_len  <= (w_rem > w_cap) ? w_cap[8:0] : w_rem[8:0];
                    wb_left <= (w_rem > w_cap) ? w_cap[8:0] : w_rem[8:0];
                    wr_req <= 1; ws <= W_BURST;
                end
                W_BURST: begin
                    if (wr_go) wr_req <= 0;
                    if (sk_pop) wb_left <= wb_left - 1'b1;
                    if (wr_burst_done) begin
                        w_rem <= w_rem - wb_len; w_baddr <= w_baddr + {wb_len, 2'b00};
                        if (w_rem != {1'b0, wb_len}) ws <= W_SET;
                        else if (w_seg + 1'b1 != w_nseg) begin
                            w_seg <= w_seg + 1'b1; sg_ra <= {w_slot, w_seg[7:0] + 8'd1}; ws <= W_SEGW;
                        end else begin
                            w_row <= w_row + 1'b1; w_addr <= w_addr + dst_stride; ws <= W_IDLE;
                        end
                    end
                end
                default: ws <= W_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------ fetch FSM + main FSM
    integer k;
    always @(posedge clk) begin
        fence_irq <= 0;
        cf_rd_d <= cf_rd;
        if (rst) begin
            ms <= M_IDLE; fs <= F_IDLE; job_valid <= 0; issued_total <= 0;
            pal_valid <= 0; pal_rr <= 0; pal_cur <= 0; fence <= 0; cl_pend <= 0; cl_replay <= 0;
            perf_busy <= 0; perf_pixels <= 0; perf_memwait <= 0;
            dst_base <= 0; dst_stride <= 0; tex_base <= 0; tex_stride <= 0;
        end else begin
            pt_we <= 0;
            if (pal_flush) pal_valid <= 0;
            if (ms != M_IDLE) perf_busy <= perf_busy + 1'b1;
            if (p7_v && p7_mask) perf_pixels <= perf_pixels + 1'b1;
            if (s_cmd_valid && !s_cmd_ready) perf_memwait <= perf_memwait + 1'b1;
            if (job_valid && job_ready) begin job_valid <= 0; issued_total <= issued_total + job_nw; end
            // palette translucency + map-x span while tables stream in
            if (mxl_v && rtk_d == K_PAL) begin
                pacc <= {m_rdata_q[31:24] != 8'd0 && m_rdata_q[31:24] != 8'd255, pacc[31:1]};
                if (rti_d[4:0] == 5'd31) begin
                    pt_we <= 1; pt_wa <= {pal_cur, rti_d[7:5]};
                    pt_wd <= {m_rdata_q[31:24] != 8'd0 && m_rdata_q[31:24] != 8'd255, pacc[31:1]};
                    part_cur[{rti_d[7:5], 5'd0} +: 32] <= {m_rdata_q[31:24] != 8'd0 && m_rdata_q[31:24] != 8'd255, pacc[31:1]};
                end
                if (m_rdata_q[31:24] != 8'd0 && m_rdata_q[31:24] != 8'd255) pal_partial[pal_cur] <= 1;
            end
            if (mxl_v && rtk_d == K_SRC && scan_hit) s_part[rts_d] <= 1;
            if (mxl_v && rtk_d == K_MX && !tbl_wd[12]) begin
                mx_any <= 1;
                if (!mx_any || tbl_wd[11:0] < mxmin) mxmin <= tbl_wd[11:0];
                if (!mx_any || tbl_wd[11:0] > mxmax) mxmax <= tbl_wd[11:0];
            end
            case (ms)
                M_IDLE: if (!cf_empty) begin ms <= M_LOAD; ld_req <= 0; ld_got <= 0; end
                    else if (cl_pend) begin
                        if (cl_hold != 0) cl_hold <= cl_hold - 1'b1;
                        else begin
                        op <= OP_CLEAR; flipx <= 0; flipy <= 0; blend <= 0; fog <= 0; alt1 <= 0;
                        dx <= cl_w1[15:0]; dy <= cl_w1[31:16]; W <= cl_w2[15:0]; H <= cl_w2[31:16];
                        clear_col <= cl_col; cl_pend <= 0; ms <= M_INIT; cl_replay <= 0;
                        end
                    end
                M_LOAD: begin
                    if (cf_rd) ld_req <= ld_req + 1'b1;
                    if (cf_rd_d) begin cw[ld_got[2:0]] <= cf_data; ld_got <= ld_got + 1'b1; end
                    if (ld_got == 4'd8) ms <= M_DEC;
                end
                M_DEC: if (cl_pend && !(cw[0][3:0] == OP_CLEAR && cw[1] == cl_w1 && cw[2] == cl_w2)) begin
                        op <= OP_CLEAR; flipx <= 0; flipy <= 0; blend <= 0; fog <= 0; alt1 <= 0;
                        dx <= cl_w1[15:0]; dy <= cl_w1[31:16]; W <= cl_w2[15:0]; H <= cl_w2[31:16];
                        clear_col <= cl_col; cl_pend <= 0; ms <= M_INIT; cl_replay <= 1;
                end else if (cw[0][3:0] == OP_CLEAR && cw[2][15:0] != 0 && cw[2][31:16] != 0) begin
                    cl_pend <= 1; cl_w1 <= cw[1]; cl_w2 <= cw[2]; cl_col <= cw[4]; cl_hold <= 8'd255; ms <= M_IDLE;
                end else begin
                    op <= cw[0][3:0]; flipx <= cw[0][4]; flipy <= cw[0][5]; blend <= cw[0][7:6]; fog <= cw[0][8];
                    dx <= cw[1][15:0]; dy <= cw[1][31:16]; W <= cw[2][15:0]; H <= cw[2][31:16];
                    sx <= cw[3][15:0]; sy <= cw[3][31:16]; colour <= cw[4][23:0]; clear_col <= cw[4];
                    a255 <= cw[5][7:0]; alt1 <= cw[5][8]; a16 <= cw[5][31:16];
                    ms <= M_IDLE;
                    case (cw[0][3:0])
                        OP_SETDST: begin dst_base <= cw[1]; dst_stride <= cw[2][15:0]; end
                        OP_SETTEX: begin
                            tex_base <= cw[1]; tex_stride <= cw[2][15:0];
                            if (pal_valid[0] && pal_tag[0] == cw[3] && !cw[0][10]) begin pal_cur <= 2'd0; pc_i <= 0; ms <= M_PCPY; end
                            else if (pal_valid[1] && pal_tag[1] == cw[3] && !cw[0][10]) begin pal_cur <= 2'd1; pc_i <= 0; ms <= M_PCPY; end
                            else if (pal_valid[2] && pal_tag[2] == cw[3] && !cw[0][10]) begin pal_cur <= 2'd2; pc_i <= 0; ms <= M_PCPY; end
                            else if (pal_valid[3] && pal_tag[3] == cw[3] && !cw[0][10]) begin pal_cur <= 2'd3; pc_i <= 0; ms <= M_PCPY; end
                            else begin
                                pal_cur <= pal_rr; pal_rr <= pal_rr + 1'b1; pal_tag[pal_rr] <= cw[3];
                                pal_valid[pal_rr] <= 1; pal_partial[pal_rr] <= 0;
                                job_valid <= 1; job_kind <= K_PAL; job_slot <= 0; job_addr <= cw[3]; job_nw <= 11'd256;
                                ms <= M_WAIT;
                            end
                        end
                        OP_FENCE: begin fence <= cw[1]; fence_irq <= cw[0][9]; end
                        OP_BLIT, OP_FILL, OP_CLEAR:
                            if (cw[2][15:0] != 0 && cw[2][31:16] != 0) ms <= M_INIT;
                        OP_MAP:
                            if (cw[2][15:0] != 0 && cw[2][31:16] != 0) begin
                                mx_any <= 0;
                                job_valid <= 1; job_kind <= K_MX; job_slot <= 0; job_addr <= cw[6]; job_nw <= {1'b0, cw[2][9:0]};
                                ms <= M_MXW;
                            end
                        default: ;
                    endcase
                end
                M_PCPY: begin   // partram word pc_i-1 is on pt_rd
                    if (pc_i != 0) part_cur[{pc_i[2:0] - 3'd1, 5'd0} +: 32] <= pt_rd;
                    pc_i <= pc_i + 1'b1;
                    if (pc_i == 4'd8) ms <= M_IDLE;
                end
                M_WAIT: if (!job_valid && rs == R_IDLE && returned_total == issued_total) ms <= M_IDLE;
                M_MXW: if (!job_valid && rs == R_IDLE && returned_total == issued_total && !mxl_v) begin
                    job_valid <= 1; job_kind <= K_MY; job_addr <= cw[7]; job_nw <= H[10:0];
                    ms <= M_MYW;
                end
                M_MYW: if (!job_valid && rs == R_IDLE && returned_total == issued_total) ms <= M_INIT;
                M_INIT: begin
                    prod_init <= dy * dst_stride;
                    needs_dst <= (op == OP_CLEAR) ? 1'b0 :
                                 (op == OP_FILL) ? (blend == 2'd1 || blend == 2'd3 || alt1) :
                                 (blend == 2'd1 || blend == 2'd3 || alt1 || pal_partial[pal_cur]);
                    // normal blend, alpha 1: a texel's result depends on the destination only if its
                    // palette alpha is translucent, so such rows are checked after the source arrives
                    dst_scan  <= (op == OP_BLIT || op == OP_MAP) && !(blend == 2'd1 || blend == 2'd3 || alt1);
                    ms <= M_INIT2;
                end
                M_INIT2: begin
                    fdst_addr <= dst_base + prod_init + {dx, 2'b00};
                    f_row <= 0; fd_row <= 0; f_issued <= 0; s_skip <= 0;
                    fs <= F_IDLE;
                    ms <= M_ROWS;
                end
                M_ROWS: if (w_row == H && !job_valid) begin ms <= cl_replay ? M_DEC : M_IDLE; cl_replay <= 0; end
                default: ms <= M_IDLE;
            endcase

            // ---------------- fetch stage
            if (ms == M_ROWS) begin
                // rows whose data has fully arrived
                if (fd_row < f_issued && ($signed(returned_total - mark[fd_row[0]]) >= 0)) fd_row <= fd_row + 1'b1;
                case (fs)
                    F_IDLE: if (f_row < H && f_row < comp + 2'd2) fs <= F_A;
                    F_A: begin
                        f_skip <= is_map && (my_rd[12] || !mx_any);
                        f_srow <= is_map ? (sy + {4'd0, my_rd[11:0]}) : (flipy ? (sy + H - 1'b1 - f_row) : (sy + f_row));
                        fs <= F_B;
                    end
                    F_B: begin f_prod <= f_srow * tex_stride; fs <= F_C; end
                    F_C: begin
                        f_saddr <= tex_base + f_prod + sx + (is_map ? {20'd0, mxmin} : 32'd0);
                        fs <= F_D;
                    end
                    F_D: begin
                        f_nw <= ({9'd0, f_saddr[1:0]} + span_bytes + 11'd3) >> 2;
                        if (!f_skip && has_src && !job_valid) begin
                            job_valid <= 1; job_kind <= K_SRC; job_slot <= f_row[0]; job_addr <= f_saddr;
                            job_nw <= ({9'd0, f_saddr[1:0]} + span_bytes + 11'd3) >> 2;
                            s_part[f_row[0]] <= 1'b0;
                        end
                        fs <= F_E;
                    end
                    F_E: if (!job_valid) begin
                        smark <= issued_total;
                        s_dst[f_row[0]] <= 1'b0;
                        if (!f_skip && needs_dst) begin
                            if (dst_scan) fs <= F_S;
                            else begin
                                job_valid <= 1; job_kind <= K_DST; job_slot <= f_row[0]; job_addr <= fdst_addr; job_nw <= W[10:0];
                                s_dst[f_row[0]] <= 1'b1;
                                fs <= F_W;
                            end
                        end else fs <= F_W;
                    end
                    // wait for the whole source row (returned_total), one more cycle for its scan flag
                    F_S: if ($signed(returned_total - smark) >= 0) fs <= F_S2;
                    F_S2: begin
                        if (s_part[f_row[0]]) begin
                            job_valid <= 1; job_kind <= K_DST; job_slot <= f_row[0]; job_addr <= fdst_addr; job_nw <= W[10:0];
                            s_dst[f_row[0]] <= 1'b1;
                        end
                        fs <= F_W;
                    end
                    F_W: if (!job_valid) begin
                        // issued_total is final for this row once the last job was accepted
                        mark[f_row[0]] <= issued_total;
                        s_boff[f_row[0]] <= f_saddr[1:0];
                        s_skip[f_row[0]] <= f_skip;
                        f_row <= f_row + 1'b1; f_issued <= f_row + 1'b1;
                        fdst_addr <= fdst_addr + dst_stride;
                        fs <= F_IDLE;
                    end
                    default: fs <= F_IDLE;
                endcase
            end
        end
    end
`ifdef BLIT_PROF
    // ------------------------------------------------------------------ simulation-only profile
    // (Verilator, -DBLIT_PROF): printed at every FENCE whose value is 0xD0D0 (firmware/bench).
    reg [31:0] pr_st [0:15]; reg [31:0] pr_rdw, pr_wrw, pr_wrs, pr_crun, pr_cfetch, pr_cwr, pr_cdone,
               pr_arb_me, pr_arb_oth, pr_arb_idle, pr_arb_ow, pr_arb_pm, pr_arb_none, pr_acc_r, pr_acc_w, pr_beat_r, pr_beat_w, pr_cmds, pr_rows;
    integer pi;
    initial begin for (pi = 0; pi < 16; pi = pi + 1) pr_st[pi] = 0;
        pr_rdw = 0; pr_wrw = 0; pr_wrs = 0; pr_crun = 0; pr_cfetch = 0; pr_cwr = 0; pr_cdone = 0;
        pr_arb_me = 0; pr_arb_oth = 0; pr_arb_idle = 0; pr_acc_r = 0; pr_acc_w = 0; pr_beat_r = 0; pr_beat_w = 0; pr_cmds = 0; pr_rows = 0; pr_arb_ow = 0; pr_arb_pm = 0; pr_arb_none = 0; end
    always @(posedge clk) if (ms != M_IDLE || !cf_empty) begin
        pr_st[ms] <= pr_st[ms] + 1;
        if (ps == P_RC && !s_cmd_ready) pr_rdw <= pr_rdw + 1;
        if (ps == P_WC && !s_cmd_ready) pr_wrw <= pr_wrw + 1;
        if (ws == W_BURST && wr_req && sk_cnt == 0) pr_wrs <= pr_wrs + 1;
        if (s_wready && sk_cnt == 0) $display("BLITPROF ERROR: write beat pulled from an empty skid buffer");
        if (rows_on) begin
            if (c_run) pr_crun <= pr_crun + 1;
            else if (!c_can) begin
                if (c_row >= H) pr_cdone <= pr_cdone + 1;
                else if (c_row >= fd_row) pr_cfetch <= pr_cfetch + 1;
                else pr_cwr <= pr_cwr + 1;
            end
        end
        if (vl_top.soc.arb.busy && vl_top.soc.arb.owner == 3'd5) pr_arb_me <= pr_arb_me + 1;
        else if (vl_top.soc.arb.busy) pr_arb_oth <= pr_arb_oth + 1;
        else if (vl_top.soc.arb.p_valid[5]) pr_arb_idle <= pr_arb_idle + 1;
        else if (vl_top.soc.arb.p_valid != 0) pr_arb_ow <= pr_arb_ow + 1;
        else if (wr_req || rd_req) pr_arb_pm <= pr_arb_pm + 1;
        else pr_arb_none <= pr_arb_none + 1;
        if (vl_top.soc.arb.c_valid && vl_top.soc.arb.c_ready && vl_top.soc.arb.sel == 3'd5) begin
            if (vl_top.soc.arb.c_we) begin pr_acc_w <= pr_acc_w + 1; pr_beat_w <= pr_beat_w + vl_top.soc.arb.c_len + 1; end
            else begin pr_acc_r <= pr_acc_r + 1; pr_beat_r <= pr_beat_r + vl_top.soc.arb.c_len + 1; end
        end
        if (ms == M_INIT) pr_cmds <= pr_cmds + 1;
        if (p7_v && p7_last) pr_rows <= pr_rows + 1;
        if (ms == M_DEC && cw[0][3:0] == OP_FENCE && cw[1] == 32'hD0D0) begin
            $display("BLITPROF draws %0d rows %0d | states idle %0d load %0d dec %0d wait(pal) %0d mxw %0d myw %0d init %0d init2 %0d rows %0d",
                pr_cmds, pr_rows, pr_st[M_IDLE], pr_st[M_LOAD], pr_st[M_DEC], pr_st[M_WAIT], pr_st[M_MXW], pr_st[M_MYW], pr_st[M_INIT], pr_st[M_INIT2], pr_st[M_ROWS]);
            $display("BLITPROF port: rd-wait %0d wr-wait %0d wr-starved %0d | compute run %0d stall-fetch %0d stall-write %0d drain %0d",
                pr_rdw, pr_wrw, pr_wrs, pr_crun, pr_cfetch, pr_cwr, pr_cdone);
            $display("BLITPROF sdram: blitter-owned %0d other-owned %0d idle: blitter cmd waiting %0d other waiting %0d engine req in port %0d nothing %0d | blitter acc rd %0d (%0d beats) wr %0d (%0d beats)",
                pr_arb_me, pr_arb_oth, pr_arb_idle, pr_arb_ow, pr_arb_pm, pr_arb_none, pr_acc_r, pr_beat_r, pr_acc_w, pr_beat_w);
        end
    end
`endif
endmodule
