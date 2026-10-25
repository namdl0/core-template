// UFO 50 audio mixer core: 32 voices (IMA ADPCM / PCM16, mono/stereo, loops), per-voice
// gain with linear fades, pan, pitch step, 8 groups, master; one stereo sample per
// out_valid/out_ready handshake. Bit-exact with sim/periph/model/mixer_model.c.
// Voices are processed one after another; each voice's state is a 4 x 128-bit record.
module mix_core (
    input  wire        clk,
    input  wire        rst,
    input  wire        en,
    // commands {key[10:0], data[31:0]} (key = byte address [12:2]); data valid the cycle after cf_rd
    input  wire        cf_empty,
    output wire        cf_rd,
    input  wire [42:0] cf_data,
    // output samples
    output reg         out_valid,
    input  wire        out_ready,
    output reg  [15:0] out_l,
    output reg  [15:0] out_r,
    // voice status for the CPU: word {v, 0} flags, {v, 1} position
    output reg         st_we,
    output reg  [5:0]  st_wa,
    output reg  [31:0] st_wd,
    output reg  [31:0] samples,
    output reg  [15:0] last_cycles,
    // memory master (reads only)
    output reg         m_valid,
    input  wire        m_ready,
    output reg  [31:0] m_addr,
    output reg  [8:0]  m_len,
    input  wire [31:0] m_rdata,
    input  wire        m_rvalid
);
    // ------------------------------------------------------------------ voice record RAM
    reg         vr_we; reg [6:0] vr_wa; reg [127:0] vr_wd; reg [6:0] vr_ra; wire [127:0] vr_rd;
    periph_ram #(.AW(7), .DW(128)) vram (.clk(clk), .we(vr_we), .wa(vr_wa), .wd(vr_wd), .ra(vr_ra), .rd(vr_rd));
    reg         lb_we; reg [7:0] lb_wa; reg [31:0] lb_wd; reg [7:0] lb_ra; wire [31:0] lb_rd;
    periph_ram #(.AW(8), .DW(32)) lbuf (.clk(clk), .we(lb_we), .wa(lb_wa), .wd(lb_wd), .ra(lb_ra), .rd(lb_rd));

    // working copy of one voice
    reg [25:0] base, hdr; reg [23:0] len, ls, start;
    reg [19:0] step; reg [15:0] panl, panr, target; reg [23:0] gain, gstep; reg fading, gup; reg [6:0] fmt;
    reg [23:0] pos, dpos, dfr; reg [15:0] frac; reg [7:0] skip; reg playing, paused, seekp, ended, tagv; reg [7:0] tag;
    reg signed [15:0] al, ar, bl, br, predl, predr; reg [6:0] idxl, idxr;
    wire adpcm = fmt[0], stereo = fmt[1], loop = fmt[2], interp = fmt[3]; wire [2:0] grp = fmt[6:4];
    wire [127:0] w0 = {4'd0, start, ls, len, hdr, base};
    wire [127:0] w1 = {3'd0, fmt, gup, fading, gstep, target, gain, panr, panl, step};
    wire [127:0] w2 = {19'd0, tag, tagv, ended, seekp, paused, playing, skip, dfr, dpos, frac, pos};
    wire [127:0] w3 = {18'd0, idxr, predr, idxl, predl, br, bl, ar, al};

    // globals
    reg [15:0] master;
    reg [23:0] ggain [0:7]; reg [15:0] gtarget [0:7]; reg [23:0] ggstep [0:7]; reg [7:0] gfading, ggup;

    // ------------------------------------------------------------------ IMA decoders
    function [22:0] ima;   // {idx[6:0], pred[15:0]}
        input signed [15:0] p; input [6:0] i; input [3:0] n;
        reg [14:0] st; reg [16:0] diff; reg signed [17:0] np; reg signed [7:0] ni;
        begin
            case (i)
             0:st=7; 1:st=8; 2:st=9; 3:st=10; 4:st=11; 5:st=12; 6:st=13; 7:st=14; 8:st=16; 9:st=17; 10:st=19; 11:st=21;
             12:st=23; 13:st=25; 14:st=28; 15:st=31; 16:st=34; 17:st=37; 18:st=41; 19:st=45; 20:st=50; 21:st=55; 22:st=60;
             23:st=66; 24:st=73; 25:st=80; 26:st=88; 27:st=97; 28:st=107; 29:st=118; 30:st=130; 31:st=143; 32:st=157;
             33:st=173; 34:st=190; 35:st=209; 36:st=230; 37:st=253; 38:st=279; 39:st=307; 40:st=337; 41:st=371; 42:st=408;
             43:st=449; 44:st=494; 45:st=544; 46:st=598; 47:st=658; 48:st=724; 49:st=796; 50:st=876; 51:st=963; 52:st=1060;
             53:st=1166; 54:st=1282; 55:st=1411; 56:st=1552; 57:st=1707; 58:st=1878; 59:st=2066; 60:st=2272; 61:st=2499;
             62:st=2749; 63:st=3024; 64:st=3327; 65:st=3660; 66:st=4026; 67:st=4428; 68:st=4871; 69:st=5358; 70:st=5894;
             71:st=6484; 72:st=7132; 73:st=7845; 74:st=8630; 75:st=9493; 76:st=10442; 77:st=11487; 78:st=12635; 79:st=13899;
             80:st=15289; 81:st=16818; 82:st=18500; 83:st=20350; 84:st=22385; 85:st=24623; 86:st=27086; 87:st=29794;
             default: st=32767;
            endcase
            diff = {5'd0, st[14:3]};
            if (n[2]) diff = diff + st;
            if (n[1]) diff = diff + st[14:1];
            if (n[0]) diff = diff + st[14:2];
            np = n[3] ? ($signed({p[15], p[15], p}) - $signed({1'b0, diff})) : ($signed({p[15], p[15], p}) + $signed({1'b0, diff}));
            if (np > 18'sd32767) np = 18'sd32767;
            if (np < -18'sd32768) np = -18'sd32768;
            ni = $signed({1'b0, i}) + (n[2] ? $signed({5'd0, n[1:0], 1'b0}) + 8'sd2 : -8'sd1);
            if (ni < 0) ni = 0;
            if (ni > 88) ni = 88;
            ima = {ni[6:0], np[15:0]};
        end
    endfunction

    // ------------------------------------------------------------------ helpers
    function [15:0] sat16u; input [31:0] x; begin sat16u = (x > 32'hFFFF) ? 16'hFFFF : x[15:0]; end endfunction

    // fade start: needs |t - gain| / n (serial divider)
    reg [23:0] dv_num, dv_den, dv_q; reg [24:0] dv_rem; reg [4:0] dv_cnt;

    // frame address of dfr
    wire [25:0] f_off = adpcm ? (stereo ? {2'd0, dfr} : {3'd0, dfr[23:1]}) : (stereo ? {dfr, 2'b00} : {1'b0, dfr, 1'b0});
    wire [25:0] f_addr = base + f_off;
    wire        lb_hit = tagv && tag == f_addr[12:5];
    wire [23:0] dpos1 = dpos + 1'b1, pos1 = pos + 1'b1;
    wire [23:0] target_pos = (pos1 == len) ? (loop ? ls : len) : pos1;

    // ------------------------------------------------------------------ FSM
    localparam S_INIT = 5'd0, S_IDLE = 5'd1, S_CMD = 5'd2, S_CMD1 = 5'd3, S_LOAD = 5'd4, S_CAPPLY = 5'd5, S_DIV = 5'd6,
               S_STORE = 5'd7, S_VSTART = 5'd8, S_VCHK = 5'd9, S_VSEEK = 5'd10, S_REPOS = 5'd11, S_HDR = 5'd12,
               S_VADV = 5'd13, S_FILL = 5'd14, S_RD = 5'd15, S_DEC = 5'd16, S_MIX0 = 5'd17, S_MIX1 = 5'd18,
               S_MIX2 = 5'd19, S_MIX3 = 5'd20, S_VNEXT = 5'd21, S_OUT = 5'd22, S_OWAIT = 5'd23, S_RDW = 5'd24;
    reg [4:0]  s, s_ret, s_ret2;
    reg [4:0]  v;
    reg [2:0]  lc;                 // load counter
    reg [1:0]  sc;                 // store counter
    reg        st_all;             // store words 0..3 (command) or 1..3 (processing)
    reg [42:0] cmd;
    reg        div_grp; reg [2:0] div_g;
    reg [7:0]  init_cnt;
    reg [23:0] rp;                 // reposition target
    reg [3:0]  beats;
    reg        hdr_r;
    reg [25:0] fa;                 // frame address being decoded
    reg signed [31:0] accl, accr;
    reg signed [16:0] dl, dr; reg signed [33:0] pl, pr;
    reg signed [16:0] sl, sr; reg [15:0] g1, gl, gr;
    reg [15:0] cyc;
    assign cf_rd = (s == S_CMD) && !cf_empty;

    wire [7:0]  lb_byte = fa[1:0] == 2'd0 ? lb_rd[7:0] : fa[1:0] == 2'd1 ? lb_rd[15:8] : fa[1:0] == 2'd2 ? lb_rd[23:16] : lb_rd[31:24];
    wire [22:0] decl = ima(predl, idxl, (stereo || !dfr[0]) ? lb_byte[3:0] : lb_byte[7:4]);
    wire [22:0] decr = ima(predr, idxr, lb_byte[7:4]);
    wire [15:0] pcm_l = stereo ? lb_rd[15:0] : (fa[1] ? lb_rd[31:16] : lb_rd[15:0]);
    wire [15:0] pcm_r = stereo ? lb_rd[31:16] : pcm_l;

    // fade step for the loaded voice (combinational result)
    wire [23:0] vt = {target, 8'd0};
    wire        v_reach = gup ? (gain >= vt || vt - gain <= gstep) : (gain <= vt || gain - vt <= gstep);
    wire [23:0] v_next = v_reach ? vt : (gup ? gain + gstep : gain - gstep);

    wire [10:0] key = cmd[42:32]; wire [31:0] cd = cmd[31:0];
    wire signed [47:0] ol = accl * $signed({1'b0, master}), orr = accr * $signed({1'b0, master});
    wire signed [47:0] ols = ol >>> 14, ors = orr >>> 14;
    integer gi;
    wire signed [33:0] cl = sl * $signed({1'b0, gl}), cr = sr * $signed({1'b0, gr});

    always @(posedge clk) begin
        vr_we <= 0; lb_we <= 0; st_we <= 0;
        if (rst) begin
            s <= S_INIT; init_cnt <= 0; out_valid <= 0; m_valid <= 0; samples <= 0; master <= 16'h4000;
            for (gi = 0; gi < 8; gi = gi + 1) begin ggain[gi] <= 24'h400000; gtarget[gi] <= 0; ggstep[gi] <= 0; end
            gfading <= 0; ggup <= 0; cyc <= 0; last_cycles <= 0;
        end else begin
            cyc <= cyc + 1'b1;
            case (s)
            S_INIT: begin   // default records: pan 1.0, step 1.0
                vr_we <= 1; vr_wa <= init_cnt[6:0];
                vr_wd <= (init_cnt[1:0] == 2'd1) ? {3'd0, 7'd0, 1'b0, 1'b0, 24'd0, 16'd0, 24'd0, 16'h8000, 16'h8000, 20'h10000} : 128'd0;
                st_we <= 1; st_wa <= init_cnt[5:0]; st_wd <= 0;
                init_cnt <= init_cnt + 1'b1;
                if (init_cnt == 8'd127) s <= S_IDLE;
            end
            S_IDLE: if (en && !out_valid) begin s <= S_CMD; cyc <= 0; end
            // ---------------- commands
            S_CMD: if (cf_empty) s <= S_VSTART; else s <= S_CMD1;
            S_CMD1: begin
                cmd <= cf_data;
                if (cf_data[42:32] == 11'h004) begin master <= cf_data[15:0]; s <= S_CMD; end
                else if (cf_data[42:37] == 6'b010000) begin   // groups 0x200-0x21F
                    case (cf_data[33:32])
                        2'd0: begin ggain[cf_data[36:34]] <= {cf_data[15:0], 8'd0}; gfading[cf_data[36:34]] <= 0; s <= S_CMD; end
                        2'd1: begin gtarget[cf_data[36:34]] <= cf_data[15:0]; s <= S_CMD; end
                        2'd2: begin
                            div_grp <= 1; div_g <= cf_data[36:34];
                            if (cf_data[23:0] == 0 || {gtarget[cf_data[36:34]], 8'd0} == ggain[cf_data[36:34]]) begin
                                ggain[cf_data[36:34]] <= {gtarget[cf_data[36:34]], 8'd0}; gfading[cf_data[36:34]] <= 0; s <= S_CMD;
                            end else begin
                                ggup[cf_data[36:34]] <= {gtarget[cf_data[36:34]], 8'd0} > ggain[cf_data[36:34]];
                                dv_num <= ({gtarget[cf_data[36:34]], 8'd0} > ggain[cf_data[36:34]]) ? {gtarget[cf_data[36:34]], 8'd0} - ggain[cf_data[36:34]]
                                                                                                    : ggain[cf_data[36:34]] - {gtarget[cf_data[36:34]], 8'd0};
                                dv_den <= cf_data[23:0]; dv_rem <= 0; dv_cnt <= 0; s <= S_DIV;
                            end
                        end
                        default: s <= S_CMD;
                    endcase
                end else if (cf_data[42:41] == 2'b10) begin   // voices 0x400-0x5FF
                    v <= cf_data[40:36]; lc <= 0; s_ret <= S_CAPPLY; s <= S_LOAD;
                end else s <= S_CMD;
            end
            S_LOAD: begin
                vr_ra <= {v, lc[1:0]};
                lc <= lc + 1'b1;
                if (lc >= 3'd2) case (lc - 3'd2)   // data of word lc-2 (address set the cycle before last)
                    3'd0: {start, ls, len, hdr, base} <= vr_rd[123:0];
                    3'd1: {fmt, gup, fading, gstep, target, gain, panr, panl, step} <= vr_rd[124:0];
                    3'd2: {tag, tagv, ended, seekp, paused, playing, skip, dfr, dpos, frac, pos} <= vr_rd[108:0];
                    default: {idxr, predr, idxl, predl, br, bl, ar, al} <= vr_rd[109:0];
                endcase
                if (lc == 3'd5) s <= s_ret;
            end
            S_CAPPLY: begin
                s <= S_STORE; sc <= 0; st_all <= 1; div_grp <= 0;
                case (key[3:0])
                    4'd0: begin
                        if (cd[0]) begin playing <= 1; paused <= 0; ended <= 0; pos <= start; frac <= 0; seekp <= 1; end
                        if (cd[4]) begin pos <= start; frac <= 0; seekp <= 1; end
                        if (cd[1]) playing <= 0;
                        if (cd[2]) paused <= 1;
                        if (cd[3]) paused <= 0;
                    end
                    4'd1: fmt <= cd[6:0];
                    4'd2: base <= cd[25:0];
                    4'd3: hdr <= cd[25:0];
                    4'd4: len <= cd[23:0];
                    4'd5: ls <= cd[23:0];
                    4'd6: start <= cd[23:0];
                    4'd7: step <= cd[19:0];
                    4'd8: begin gain <= {cd[15:0], 8'd0}; fading <= 0; end
                    4'd9: target <= cd[15:0];
                    4'd10: if (cd[23:0] == 0 || vt == gain) begin gain <= vt; fading <= 0; end
                           else begin
                               gup <= vt > gain; dv_num <= vt > gain ? vt - gain : gain - vt;
                               dv_den <= cd[23:0]; dv_rem <= 0; dv_cnt <= 0; s <= S_DIV;
                           end
                    4'd11: begin panl <= cd[15:0]; panr <= cd[31:16]; end
                    default: ;
                endcase
            end
            S_DIV: begin   // restoring division dv_num / dv_den, 24 steps
                if (dv_cnt == 5'd24) begin
                    if (div_grp) begin ggstep[div_g] <= dv_q == 0 ? 24'd1 : dv_q; gfading[div_g] <= 1; s <= S_CMD; end
                    else begin gstep <= dv_q == 0 ? 24'd1 : dv_q; fading <= 1; s <= S_STORE; end
                end else begin
                    if ({dv_rem[23:0], dv_num[23]} >= {1'b0, dv_den}) begin
                        dv_rem <= {dv_rem[23:0], dv_num[23]} - {1'b0, dv_den}; dv_q <= {dv_q[22:0], 1'b1};
                    end else begin
                        dv_rem <= {dv_rem[23:0], dv_num[23]}; dv_q <= {dv_q[22:0], 1'b0};
                    end
                    dv_num <= {dv_num[22:0], 1'b0}; dv_cnt <= dv_cnt + 1'b1;
                end
            end
            S_STORE: begin
                vr_we <= 1; vr_wa <= {v, st_all ? sc : sc + 2'd1};
                case (st_all ? sc : sc + 2'd1)
                    2'd0: vr_wd <= w0; 2'd1: vr_wd <= w1; 2'd2: vr_wd <= w2; default: vr_wd <= w3;
                endcase
                sc <= sc + 1'b1;
                if (sc == 2'd0) begin st_we <= 1; st_wa <= {v, 1'b0}; st_wd <= {29'd0, ended, paused, playing}; end
                if (sc == 2'd1) begin st_we <= 1; st_wa <= {v, 1'b1}; st_wd <= {8'd0, pos}; end
                if (sc == (st_all ? 2'd3 : 2'd2)) s <= st_all ? S_CMD : S_VNEXT;
            end
            // ---------------- voices
            S_VSTART: begin v <= 0; accl <= 0; accr <= 0; lc <= 0; s_ret <= S_VCHK; s <= S_LOAD; end
            S_VCHK: begin
                if (!playing || paused) s <= S_VNEXT;
                else if (pos >= len) begin
                    if (loop) begin pos <= pos - (len - ls); s <= S_VSEEK; end
                    else begin playing <= 0; ended <= 1; sc <= 0; st_all <= 0; s <= S_STORE; end
                end else s <= S_VSEEK;
            end
            S_VSEEK: if (seekp) begin
                    rp <= pos; al <= 0; ar <= 0; bl <= 0; br <= 0; seekp <= 0; s_ret2 <= S_VADV; s <= S_REPOS;
                end else s <= S_VADV;
            S_REPOS: begin
                dpos <= rp - 1'b1; tagv <= 0;
                if (adpcm) begin
                    dfr <= {rp[23:8], 8'd0}; skip <= rp[7:0];
                    m_valid <= 1; m_addr <= {6'd0, hdr + (stereo ? {rp[23:8], 3'b000} : {1'b0, rp[23:8], 2'b00})};
                    m_len <= stereo ? 9'd2 : 9'd1; beats <= 0; s <= S_HDR;
                end else begin dfr <= rp; skip <= 0; s <= s_ret2; end
            end
            S_HDR: begin
                if (m_valid && m_ready) m_valid <= 0;
                if (m_rvalid) begin
                    beats <= beats + 1'b1;
                    if (beats == 0) begin predl <= m_rdata[15:0]; idxl <= m_rdata[22:16]; end
                    else begin predr <= m_rdata[15:0]; idxr <= m_rdata[22:16]; end
                    if (beats + 1'b1 == (stereo ? 4'd2 : 4'd1)) s <= s_ret2;
                end
            end
            S_VADV: begin
                if (dpos == target_pos) s <= S_MIX0;
                else if (skip == 0 && dpos1 == len) begin
                    if (loop) begin rp <= ls; s_ret2 <= S_VADV; s <= S_REPOS; end
                    else begin al <= bl; ar <= br; dpos <= len; end
                end else if (!lb_hit) begin
                    m_valid <= 1; m_addr <= {6'd0, f_addr[25:5], 5'd0}; m_len <= 9'd8; beats <= 0; s <= S_FILL;
                    tag <= f_addr[12:5];
                end else begin
                    lb_ra <= {v, f_addr[4:2]}; fa <= f_addr; s <= S_RD;
                end
            end
            S_FILL: begin
                if (m_valid && m_ready) m_valid <= 0;
                if (m_rvalid) begin
                    lb_we <= 1; lb_wa <= {v, beats[2:0]}; lb_wd <= m_rdata; beats <= beats + 1'b1;
                    if (beats == 4'd7) begin tagv <= 1; s <= S_VADV; end
                end
            end
            S_RD: s <= S_DEC;
            S_DEC: begin
                dfr <= dfr + 1'b1;
                if (adpcm) begin
                    predl <= decl[15:0]; idxl <= decl[22:16];
                    if (stereo) begin predr <= decr[15:0]; idxr <= decr[22:16]; end
                end
                if (skip != 0) skip <= skip - 1'b1;
                else begin
                    al <= bl; ar <= br; dpos <= dpos1;
                    if (adpcm) begin bl <= decl[15:0]; br <= stereo ? decr[15:0] : decl[15:0]; end
                    else begin bl <= pcm_l; br <= pcm_r; end
                end
                s <= S_VADV;
            end
            S_MIX0: begin
                dl <= $signed({bl[15], bl}) - $signed({al[15], al});
                dr <= $signed({br[15], br}) - $signed({ar[15], ar});
                g1 <= sat16u(({16'd0, gain[23:8]} * {16'd0, ggain[grp][23:8]}) >> 14);
                s <= S_MIX1;
            end
            S_MIX1: begin
                pl <= dl * $signed({1'b0, frac}); pr <= dr * $signed({1'b0, frac});
                gl <= sat16u(({16'd0, g1} * {16'd0, panl}) >> 15); gr <= sat16u(({16'd0, g1} * {16'd0, panr}) >> 15);
                s <= S_MIX2;
            end
            S_MIX2: begin
                sl <= interp ? $signed({al[15], al}) + $signed(pl >>> 16) : $signed({al[15], al});
                sr <= interp ? $signed({ar[15], ar}) + $signed(pr >>> 16) : $signed({ar[15], ar});
                s <= S_MIX3;
            end
            S_MIX3: begin
                accl <= accl + $signed(cl[33:14]);
                accr <= accr + $signed(cr[33:14]);
                if (fading) begin gain <= v_next; if (v_reach) fading <= 0; end
                {pos, frac} <= {pos, frac} + {4'd0, step};
                sc <= 0; st_all <= 0; s <= S_STORE;
            end
            S_VNEXT: if (v == 5'd31) s <= S_OUT; else begin v <= v + 1'b1; lc <= 0; s_ret <= S_VCHK; s <= S_LOAD; end
            S_OUT: begin
                out_l <= ols > 32767 ? 16'h7FFF : ols < -32768 ? 16'h8000 : ols[15:0];
                out_r <= ors > 32767 ? 16'h7FFF : ors < -32768 ? 16'h8000 : ors[15:0];
                for (gi = 0; gi < 8; gi = gi + 1) if (gfading[gi]) begin
                    if (ggup[gi] ? (ggain[gi] >= {gtarget[gi], 8'd0} || {gtarget[gi], 8'd0} - ggain[gi] <= ggstep[gi])
                                 : (ggain[gi] <= {gtarget[gi], 8'd0} || ggain[gi] - {gtarget[gi], 8'd0} <= ggstep[gi])) begin
                        ggain[gi] <= {gtarget[gi], 8'd0}; gfading[gi] <= 0;
                    end else ggain[gi] <= ggup[gi] ? ggain[gi] + ggstep[gi] : ggain[gi] - ggstep[gi];
                end
                out_valid <= 1; last_cycles <= cyc; s <= S_OWAIT;
            end
            S_OWAIT: s <= S_IDLE;
            default: s <= S_IDLE;
            endcase
            if (out_valid && out_ready) begin out_valid <= 0; samples <= samples + 1'b1; end
        end
    end
endmodule
