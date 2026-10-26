//
// User core top-level
//
// Instantiated by the real top-level: apf_top
//

`default_nettype none

module core_top (

//
// physical connections
//

///////////////////////////////////////////////////
// clock inputs 74.25mhz. not phase aligned, so treat these domains as asynchronous

input   wire            clk_74a, // mainclk1
input   wire            clk_74b, // mainclk1 

///////////////////////////////////////////////////
// cartridge interface
// switches between 3.3v and 5v mechanically
// output enable for multibit translators controlled by pic32

// GBA AD[15:8]
inout   wire    [7:0]   cart_tran_bank2,
output  wire            cart_tran_bank2_dir,

// GBA AD[7:0]
inout   wire    [7:0]   cart_tran_bank3,
output  wire            cart_tran_bank3_dir,

// GBA A[23:16]
inout   wire    [7:0]   cart_tran_bank1,
output  wire            cart_tran_bank1_dir,

// GBA [7] PHI#
// GBA [6] WR#
// GBA [5] RD#
// GBA [4] CS1#/CS#
//     [3:0] unwired
inout   wire    [7:4]   cart_tran_bank0,
output  wire            cart_tran_bank0_dir,

// GBA CS2#/RES#
inout   wire            cart_tran_pin30,
output  wire            cart_tran_pin30_dir,
// when GBC cart is inserted, this signal when low or weak will pull GBC /RES low with a special circuit
// the goal is that when unconfigured, the FPGA weak pullups won't interfere.
// thus, if GBC cart is inserted, FPGA must drive this high in order to let the level translators
// and general IO drive this pin.
output  wire            cart_pin30_pwroff_reset,

// GBA IRQ/DRQ
inout   wire            cart_tran_pin31,
output  wire            cart_tran_pin31_dir,

// infrared
input   wire            port_ir_rx,
output  wire            port_ir_tx,
output  wire            port_ir_rx_disable, 

// GBA link port
inout   wire            port_tran_si,
output  wire            port_tran_si_dir,
inout   wire            port_tran_so,
output  wire            port_tran_so_dir,
inout   wire            port_tran_sck,
output  wire            port_tran_sck_dir,
inout   wire            port_tran_sd,
output  wire            port_tran_sd_dir,
 
///////////////////////////////////////////////////
// cellular psram 0 and 1, two chips (64mbit x2 dual die per chip)

output  wire    [21:16] cram0_a,
inout   wire    [15:0]  cram0_dq,
input   wire            cram0_wait,
output  wire            cram0_clk,
output  wire            cram0_adv_n,
output  wire            cram0_cre,
output  wire            cram0_ce0_n,
output  wire            cram0_ce1_n,
output  wire            cram0_oe_n,
output  wire            cram0_we_n,
output  wire            cram0_ub_n,
output  wire            cram0_lb_n,

output  wire    [21:16] cram1_a,
inout   wire    [15:0]  cram1_dq,
input   wire            cram1_wait,
output  wire            cram1_clk,
output  wire            cram1_adv_n,
output  wire            cram1_cre,
output  wire            cram1_ce0_n,
output  wire            cram1_ce1_n,
output  wire            cram1_oe_n,
output  wire            cram1_we_n,
output  wire            cram1_ub_n,
output  wire            cram1_lb_n,

///////////////////////////////////////////////////
// sdram, 512mbit 16bit

output  wire    [12:0]  dram_a,
output  wire    [1:0]   dram_ba,
inout   wire    [15:0]  dram_dq,
output  wire    [1:0]   dram_dqm,
output  wire            dram_clk,
output  wire            dram_cke,
output  wire            dram_ras_n,
output  wire            dram_cas_n,
output  wire            dram_we_n,

///////////////////////////////////////////////////
// sram, 1mbit 16bit

output  wire    [16:0]  sram_a,
inout   wire    [15:0]  sram_dq,
output  wire            sram_oe_n,
output  wire            sram_we_n,
output  wire            sram_ub_n,
output  wire            sram_lb_n,

///////////////////////////////////////////////////
// vblank driven by dock for sync in a certain mode

input   wire            vblank,

///////////////////////////////////////////////////
// i/o to 6515D breakout usb uart

output  wire            dbg_tx,
input   wire            dbg_rx,

///////////////////////////////////////////////////
// i/o pads near jtag connector user can solder to

output  wire            user1,
input   wire            user2,

///////////////////////////////////////////////////
// RFU internal i2c bus 

inout   wire            aux_sda,
output  wire            aux_scl,

///////////////////////////////////////////////////
// RFU, do not use
output  wire            vpll_feed,


//
// logical connections
//

///////////////////////////////////////////////////
// video, audio output to scaler
output  wire    [23:0]  video_rgb,
output  wire            video_rgb_clock,
output  wire            video_rgb_clock_90,
output  wire            video_de,
output  wire            video_skip,
output  wire            video_vs,
output  wire            video_hs,
    
output  wire            audio_mclk,
input   wire            audio_adc,
output  wire            audio_dac,
output  wire            audio_lrck,

///////////////////////////////////////////////////
// bridge bus connection
// synchronous to clk_74a
output  wire            bridge_endian_little,
input   wire    [31:0]  bridge_addr,
input   wire            bridge_rd,
output  reg     [31:0]  bridge_rd_data,
input   wire            bridge_wr,
input   wire    [31:0]  bridge_wr_data,

///////////////////////////////////////////////////
// controller data
// 
// key bitmap:
//   [0]    dpad_up
//   [1]    dpad_down
//   [2]    dpad_left
//   [3]    dpad_right
//   [4]    face_a
//   [5]    face_b
//   [6]    face_x
//   [7]    face_y
//   [8]    trig_l1
//   [9]    trig_r1
//   [10]   trig_l2
//   [11]   trig_r2
//   [12]   trig_l3
//   [13]   trig_r3
//   [14]   face_select
//   [15]   face_start
//   [31:28] type
// joy values - unsigned
//   [ 7: 0] lstick_x
//   [15: 8] lstick_y
//   [23:16] rstick_x
//   [31:24] rstick_y
// trigger values - unsigned
//   [ 7: 0] ltrig
//   [15: 8] rtrig
//
input   wire    [31:0]  cont1_key,
input   wire    [31:0]  cont2_key,
input   wire    [31:0]  cont3_key,
input   wire    [31:0]  cont4_key,
input   wire    [31:0]  cont1_joy,
input   wire    [31:0]  cont2_joy,
input   wire    [31:0]  cont3_joy,
input   wire    [31:0]  cont4_joy,
input   wire    [15:0]  cont1_trig,
input   wire    [15:0]  cont2_trig,
input   wire    [15:0]  cont3_trig,
input   wire    [15:0]  cont4_trig
    
);

// clocks, declared before their first use
    wire    clk_core_12288;
    wire    clk_core_12288_90deg;
    wire    pll_core_locked;
    wire    pll_core_locked_s;

// not using the IR port, so turn off both the LED, and
// disable the receive circuit to save power
assign port_ir_tx = 0;
assign port_ir_rx_disable = 1;

// bridge endianness
assign bridge_endian_little = 0;

// cart is unused, so set all level translators accordingly
// directions are 0:IN, 1:OUT
assign cart_tran_bank3 = 8'hzz;
assign cart_tran_bank3_dir = 1'b0;
assign cart_tran_bank2 = 8'hzz;
assign cart_tran_bank2_dir = 1'b0;
assign cart_tran_bank1 = 8'hzz;
assign cart_tran_bank1_dir = 1'b0;
assign cart_tran_bank0 = 4'hf;
assign cart_tran_bank0_dir = 1'b1;
assign cart_tran_pin30 = 1'b0;      // reset or cs2, we let the hw control it by itself
assign cart_tran_pin30_dir = 1'bz;
assign cart_pin30_pwroff_reset = 1'b0;  // hardware can control this
assign cart_tran_pin31 = 1'bz;      // input
assign cart_tran_pin31_dir = 1'b0;  // input

// link port is unused, set to input only to be safe
// each bit may be bidirectional in some applications
assign port_tran_so = 1'bz;
assign port_tran_so_dir = 1'b0;     // SO is output only
assign port_tran_si = 1'bz;
assign port_tran_si_dir = 1'b0;     // SI is input only
assign port_tran_sck = 1'bz;
assign port_tran_sck_dir = 1'b0;    // clock direction can change
assign port_tran_sd = 1'bz;
assign port_tran_sd_dir = 1'b0;     // SD is input and not used

// tie off the rest of the pins we are not using
assign cram0_a = 'h0;
assign cram0_dq = {16{1'bZ}};
assign cram0_clk = 0;
assign cram0_adv_n = 1;
assign cram0_cre = 0;
assign cram0_ce0_n = 1;
assign cram0_ce1_n = 1;
assign cram0_oe_n = 1;
assign cram0_we_n = 1;
assign cram0_ub_n = 1;
assign cram0_lb_n = 1;

assign cram1_a = 'h0;
assign cram1_dq = {16{1'bZ}};
assign cram1_clk = 0;
assign cram1_adv_n = 1;
assign cram1_cre = 0;
assign cram1_ce0_n = 1;
assign cram1_ce1_n = 1;
assign cram1_oe_n = 1;
assign cram1_we_n = 1;
assign cram1_ub_n = 1;
assign cram1_lb_n = 1;

// SDRAM: driven by the M3 SoC (soc/sdram_ctrl.v), see "UFO50 SoC" below

assign sram_a = 'h0;
assign sram_dq = {16{1'bZ}};
assign sram_oe_n  = 1;
assign sram_we_n  = 1;
assign sram_ub_n  = 1;
assign sram_lb_n  = 1;

assign dbg_tx = 1'bZ;
assign user1 = 1'bZ;
assign aux_scl = 1'bZ;
assign vpll_feed = 1'bZ;


// for bridge write data, we just broadcast it to all bus devices
// for bridge read data, we have to mux it
// add your own devices here
always @(*) begin
    casex(bridge_addr)
    default: begin
        bridge_rd_data <= 0;
    end
    32'h10xxxxxx: begin
        // example
        // bridge_rd_data <= example_device_data;
        bridge_rd_data <= 0;
    end
    32'hF8xxxxxx: begin
        bridge_rd_data <= cmd_bridge_rd_data;
    end
    endcase
end


//
// host/target command handler
//
    wire            reset_n;                // driven by host commands, can be used as core-wide reset
    wire    [31:0]  cmd_bridge_rd_data;
    
// bridge host commands
// synchronous to clk_74a
    wire            status_boot_done = pll_core_locked_s; 
    wire            status_setup_done = pll_core_locked_s; // rising edge triggers a target command
    wire            status_running = reset_n; // we are running as soon as reset_n goes high

    wire            dataslot_requestread;
    wire    [15:0]  dataslot_requestread_id;
    wire            dataslot_requestread_ack = 1;
    wire            dataslot_requestread_ok = 1;

    wire            dataslot_requestwrite;
    wire    [15:0]  dataslot_requestwrite_id;
    wire    [31:0]  dataslot_requestwrite_size;
    wire            dataslot_requestwrite_ack = 1;
    wire            dataslot_requestwrite_ok = 1;

    wire            dataslot_update;
    wire    [15:0]  dataslot_update_id;
    wire    [31:0]  dataslot_update_size;
    
    wire            dataslot_allcomplete;

    wire     [31:0] rtc_epoch_seconds;
    wire     [31:0] rtc_date_bcd;
    wire     [31:0] rtc_time_bcd;
    wire            rtc_valid;

    wire            savestate_supported;
    wire    [31:0]  savestate_addr;
    wire    [31:0]  savestate_size;
    wire    [31:0]  savestate_maxloadsize;

    wire            savestate_start;
    wire            savestate_start_ack;
    wire            savestate_start_busy;
    wire            savestate_start_ok;
    wire            savestate_start_err;

    wire            savestate_load;
    wire            savestate_load_ack;
    wire            savestate_load_busy;
    wire            savestate_load_ok;
    wire            savestate_load_err;
    
    wire            osnotify_inmenu;

// bridge target commands
// synchronous to clk_74a

    wire            target_dataslot_read;       // driven by soc/dataslot_ctrl.v
    wire            target_dataslot_write = 1'b0;
    wire            target_dataslot_getfile = 1'b0;    // require additional param/resp structs to be mapped
    wire            target_dataslot_openfile = 1'b0;   // require additional param/resp structs to be mapped
    
    wire            target_dataslot_ack;        
    wire            target_dataslot_done;
    wire    [2:0]   target_dataslot_err;

    wire    [15:0]  target_dataslot_id;
    wire    [31:0]  target_dataslot_slotoffset;
    wire    [31:0]  target_dataslot_bridgeaddr;
    wire    [31:0]  target_dataslot_length;
    
    wire    [31:0]  target_buffer_param_struct; // to be mapped/implemented when using some Target commands
    wire    [31:0]  target_buffer_resp_struct;  // to be mapped/implemented when using some Target commands
    
// bridge data slot access
// synchronous to clk_74a

    wire    [9:0]   datatable_addr;             // driven by soc/dataslot_ctrl.v (read only)
    wire            datatable_wren = 1'b0;
    wire    [31:0]  datatable_data = 32'd0;
    wire    [31:0]  datatable_q;

core_bridge_cmd icb (

    .clk                ( clk_74a ),
    .reset_n            ( reset_n ),

    .bridge_endian_little   ( bridge_endian_little ),
    .bridge_addr            ( bridge_addr ),
    .bridge_rd              ( bridge_rd ),
    .bridge_rd_data         ( cmd_bridge_rd_data ),
    .bridge_wr              ( bridge_wr ),
    .bridge_wr_data         ( bridge_wr_data ),
    
    .status_boot_done       ( status_boot_done ),
    .status_setup_done      ( status_setup_done ),
    .status_running         ( status_running ),

    .dataslot_requestread       ( dataslot_requestread ),
    .dataslot_requestread_id    ( dataslot_requestread_id ),
    .dataslot_requestread_ack   ( dataslot_requestread_ack ),
    .dataslot_requestread_ok    ( dataslot_requestread_ok ),

    .dataslot_requestwrite      ( dataslot_requestwrite ),
    .dataslot_requestwrite_id   ( dataslot_requestwrite_id ),
    .dataslot_requestwrite_size ( dataslot_requestwrite_size ),
    .dataslot_requestwrite_ack  ( dataslot_requestwrite_ack ),
    .dataslot_requestwrite_ok   ( dataslot_requestwrite_ok ),

    .dataslot_update            ( dataslot_update ),
    .dataslot_update_id         ( dataslot_update_id ),
    .dataslot_update_size       ( dataslot_update_size ),
    
    .dataslot_allcomplete   ( dataslot_allcomplete ),

    .rtc_epoch_seconds      ( rtc_epoch_seconds ),
    .rtc_date_bcd           ( rtc_date_bcd ),
    .rtc_time_bcd           ( rtc_time_bcd ),
    .rtc_valid              ( rtc_valid ),
    
    .savestate_supported    ( savestate_supported ),
    .savestate_addr         ( savestate_addr ),
    .savestate_size         ( savestate_size ),
    .savestate_maxloadsize  ( savestate_maxloadsize ),

    .savestate_start        ( savestate_start ),
    .savestate_start_ack    ( savestate_start_ack ),
    .savestate_start_busy   ( savestate_start_busy ),
    .savestate_start_ok     ( savestate_start_ok ),
    .savestate_start_err    ( savestate_start_err ),

    .savestate_load         ( savestate_load ),
    .savestate_load_ack     ( savestate_load_ack ),
    .savestate_load_busy    ( savestate_load_busy ),
    .savestate_load_ok      ( savestate_load_ok ),
    .savestate_load_err     ( savestate_load_err ),

    .osnotify_inmenu        ( osnotify_inmenu ),
    
    .target_dataslot_read       ( target_dataslot_read ),
    .target_dataslot_write      ( target_dataslot_write ),
    .target_dataslot_getfile    ( target_dataslot_getfile ),
    .target_dataslot_openfile   ( target_dataslot_openfile ),
    
    .target_dataslot_ack        ( target_dataslot_ack ),
    .target_dataslot_done       ( target_dataslot_done ),
    .target_dataslot_err        ( target_dataslot_err ),

    .target_dataslot_id         ( target_dataslot_id ),
    .target_dataslot_slotoffset ( target_dataslot_slotoffset ),
    .target_dataslot_bridgeaddr ( target_dataslot_bridgeaddr ),
    .target_dataslot_length     ( target_dataslot_length ),

    .target_buffer_param_struct ( target_buffer_param_struct ),
    .target_buffer_resp_struct  ( target_buffer_resp_struct ),
    
    .datatable_addr         ( datatable_addr ),
    .datatable_wren         ( datatable_wren ),
    .datatable_data         ( datatable_data ),
    .datatable_q            ( datatable_q )

);



////////////////////////////////////////////////////////////////////////////////////////



// video generation
//
// UFO 50 port, milestone M1: 384x216 @ 60 Hz test pattern (see core/ufo50_video.v)
//
// pixel clock: 12.288 MHz from the template PLL (outclk_0), 90 degree copy on outclk_1.
// 12,288,000 / 60 = 204,800 clocks per frame = 512 clocks/line x 400 lines.
//   H: 384 active of 512 total, V: 216 active of 400 total -> exactly 60.000 Hz.
// The PLL is unchanged from the template, so no IP regeneration is needed.
//

    wire [23:0] vidout_rgb;
    wire        vidout_de;
    wire        vidout_skip;
    wire        vidout_vs;
    wire        vidout_hs;
    wire [15:0] frame_count;

assign video_rgb_clock = clk_core_12288;
assign video_rgb_clock_90 = clk_core_12288_90deg;
assign video_rgb = vidout_rgb;
assign video_de = vidout_de;
assign video_skip = vidout_skip;
assign video_vs = vidout_vs;
assign video_hs = vidout_hs;

    wire [9:0]  vid_hcount;
    wire [9:0]  vid_vcount;
    wire [23:0] soc_fb_rgb;
    wire [1:0]  soc_vid_mode;
    wire [23:0] soc_vid_border;

ufo50_video #(
    .EXT        ( 1 ),
    .H_ACTIVE   ( 384 ),
    .H_BPORCH   ( 64 ),
    .H_TOTAL    ( 512 ),
    .V_ACTIVE   ( 216 ),
    .V_BPORCH   ( 16 ),
    .V_TOTAL    ( 400 )
) ufo50_video_inst (
    .clk            ( clk_core_12288 ),
    .reset_n        ( reset_n ),
    .keys           ( cont1_key[15:0] ),

    .rgb            ( vidout_rgb ),
    .de             ( vidout_de ),
    .hs             ( vidout_hs ),
    .vs             ( vidout_vs ),
    .skip           ( vidout_skip ),
    .frame_count    ( frame_count ),

    .src_mode       ( soc_vid_mode ),
    .fb_rgb         ( soc_fb_rgb ),
    .border_rgb     ( soc_vid_border ),
    .hcount         ( vid_hcount ),
    .vcount         ( vid_vcount )
);




//
// audio: 48 kHz I2S, 16-bit samples from the SoC (ufo50_mixer via soc audio_l/r)
//

assign audio_mclk = audgen_mclk;
assign audio_dac = audgen_dac;
assign audio_lrck = audgen_lrck;

// generate MCLK = 12.288mhz with fractional accumulator
    reg         [21:0]  audgen_accum;
    reg                 audgen_mclk;
    parameter   [20:0]  CYCLE_48KHZ = 21'd122880 * 2;
always @(posedge clk_74a) begin
    audgen_accum <= audgen_accum + CYCLE_48KHZ;
    if(audgen_accum >= 21'd742500) begin
        audgen_mclk <= ~audgen_mclk;
        audgen_accum <= audgen_accum - 21'd742500 + CYCLE_48KHZ;
    end
end

// generate SCLK = 3.072mhz by dividing MCLK by 4
    reg [1:0]   aud_mclk_divider;
    wire        audgen_sclk = aud_mclk_divider[1] /* synthesis keep*/;
always @(posedge audgen_mclk) begin
    aud_mclk_divider <= aud_mclk_divider + 1'b1;
end

// shift out audio data as I2S
// 32 total bits per channel: 16 sample bits (MSB first, one SCLK after LRCK changes),
// then 16 zero bits. The left/right samples are taken from the SoC (clk_sys) when
// the left channel starts; the SoC updates them only right after audio_tick, which
// is generated from that same moment, so they are stable here.
    reg     [4:0]   audgen_lrck_cnt;
    reg             audgen_lrck;
    reg             audgen_dac;
    reg     [15:0]  aud_sh;
    reg     [15:0]  aud_r_hold;
    reg             aud_frame_t = 1'b0;
    wire    [15:0]  soc_audio_l, soc_audio_r;
always @(negedge audgen_sclk) begin
    audgen_lrck_cnt <= audgen_lrck_cnt + 1'b1;
    audgen_dac <= 1'b0;
    if(audgen_lrck_cnt == 31) begin
        // switch channels
        audgen_lrck <= ~audgen_lrck;
        if (audgen_lrck) begin                  // 1 -> 0: left channel starts
            aud_sh      <= soc_audio_l;
            aud_r_hold  <= soc_audio_r;
            aud_frame_t <= ~aud_frame_t;
        end else
            aud_sh <= aud_r_hold;
    end else if (audgen_lrck_cnt[4] == 1'b0) begin
        audgen_dac <= aud_sh[15];
        aud_sh <= {aud_sh[14:0], 1'b0};
    end
end

    // 48 kHz tick into clk_sys
    reg [2:0]   aud_tick_s;
always @(posedge clk_sys) aud_tick_s <= {aud_tick_s[1:0], aud_frame_t};
    wire        soc_audio_tick = aud_tick_s[2] ^ aud_tick_s[1];


////////////////////////////////////////////////////////////////////////////////////////
//
// UFO50 SoC (milestone M3): VexRiscv RV32IMFD + SDRAM + framebuffer + data slots.
// See docs/MEMORY_MAP.md.
//

    // clk_sys = 57.75 MHz. To change it, edit SYS_FREQ_STR and SYS_FREQ_HZ together
    // (exact values listed in mf_pllsys.v) and the clock name in core_constraints.sdc stays valid.
    localparam  SYS_FREQ_STR = "57.750000 MHz";
    localparam  SYS_FREQ_HZ  = 32'd57_750_000;

    // M5: SDRAM in its own clock domain at 2 x clk_sys (soc/sdram_ctrl2x.v). Set SDRAM_2X to 0
    // for the M3/M4 controller (SDRAM on clk_sys, CL=2); the 115.5 MHz clock then goes unused.
    localparam  SDRAM_2X     = 1;
    localparam  MEM_FREQ_STR = "115.500000 MHz";

    wire    clk_sys;
    wire    clk_mem;
    wire    pll_sys_locked;

mf_pllsys #( .OUT_FREQ(SYS_FREQ_STR), .OUT_FREQ1(MEM_FREQ_STR) ) mp2 (
    .refclk         ( clk_74a ),
    .rst            ( 1'b0 ),
    .outclk_0       ( clk_sys ),
    .outclk_1       ( clk_mem ),
    .locked         ( pll_sys_locked )
);

    // resets: rst_mem while the PLL is unlocked (SDRAM + bridge path keep running while
    // the APF holds reset_n low, because the APF loads data slots during that time);
    // rst_sys additionally while reset_n is low (CPU and peripherals).
    reg [2:0]   rst_mem_s = 3'b111;
always @(posedge clk_sys or negedge pll_sys_locked) begin
    if (!pll_sys_locked) rst_mem_s <= 3'b111;
    else                 rst_mem_s <= {rst_mem_s[1:0], 1'b0};
end
    wire        rst_mem = rst_mem_s[2];
    reg [2:0]   reset_n_s = 3'b000;
    reg         rst_sys = 1'b1;
always @(posedge clk_sys) begin
    reset_n_s <= {reset_n_s[1:0], reset_n};
    rst_sys   <= rst_mem | ~reset_n_s[2];
end

    wire [15:0] sd_dq_out;
    wire        sd_dq_oe;
assign dram_dq = sd_dq_oe ? sd_dq_out : {16{1'bZ}};

// dram_clk = inverted SDRAM controller clock (clk_mem, or clk_sys without SDRAM_2X) through a
// DDIO output register (same IO timing as the command/data outputs): the SDRAM samples half
// a clock after the FPGA launches.
pin_ddio_clk sdram_clk_out (
    .datain_h       ( 1'b0 ),
    .datain_l       ( 1'b1 ),
    .outclock       ( SDRAM_2X ? clk_mem : clk_sys ),
    .dataout        ( dram_clk )
);

ufo50_soc #(
    .CLK_SYS_HZ     ( SYS_FREQ_HZ ),
    .BOOT_HEX       ( "core/fw/boot" ),
    .SDRAM_2X       ( SDRAM_2X )
) soc (
    .clk_sys        ( clk_sys ),
    .clk_mem        ( clk_mem ),
    .rst_mem        ( rst_mem ),
    .rst_sys        ( rst_sys ),

    .sd_a           ( dram_a ),
    .sd_ba          ( dram_ba ),
    .sd_dqm         ( dram_dqm ),
    .sd_cke         ( dram_cke ),
    .sd_ras_n       ( dram_ras_n ),
    .sd_cas_n       ( dram_cas_n ),
    .sd_we_n        ( dram_we_n ),
    .sd_dq_out      ( sd_dq_out ),
    .sd_dq_oe       ( sd_dq_oe ),
    .sd_dq_in       ( dram_dq ),

    .clk_vid        ( clk_core_12288 ),
    .vid_x          ( vid_hcount ),
    .vid_y          ( vid_vcount ),
    .vid_fb_rgb     ( soc_fb_rgb ),
    .vid_mode       ( soc_vid_mode ),
    .vid_border     ( soc_vid_border ),

    .clk_74a        ( clk_74a ),
    .bridge_addr    ( bridge_addr ),
    .bridge_wr      ( bridge_wr ),
    .bridge_wr_data ( bridge_wr_data ),
    .target_dataslot_read       ( target_dataslot_read ),
    .target_dataslot_id         ( target_dataslot_id ),
    .target_dataslot_slotoffset ( target_dataslot_slotoffset ),
    .target_dataslot_bridgeaddr ( target_dataslot_bridgeaddr ),
    .target_dataslot_length     ( target_dataslot_length ),
    .target_dataslot_ack        ( target_dataslot_ack ),
    .target_dataslot_done       ( target_dataslot_done ),
    .target_dataslot_err        ( target_dataslot_err ),
    .datatable_addr             ( datatable_addr ),
    .datatable_q                ( datatable_q ),
    .dataslot_allcomplete       ( dataslot_allcomplete ),
    .osnotify_inmenu            ( osnotify_inmenu ),
    .rtc_epoch_seconds          ( rtc_epoch_seconds ),
    .rtc_valid                  ( rtc_valid ),
    .cont_key       ( {cont4_key, cont3_key, cont2_key, cont1_key} ),
    .cont_joy       ( {cont4_joy, cont3_joy, cont2_joy, cont1_joy} ),
    .cont_trig      ( {cont4_trig, cont3_trig, cont2_trig, cont1_trig} ),

    .audio_tick     ( soc_audio_tick ),
    .audio_l        ( soc_audio_l ),
    .audio_r        ( soc_audio_r )
);


///////////////////////////////////////////////


    // (clk_core_12288, clk_core_12288_90deg, pll_core_locked[_s] are declared at the top)
synch_3 s01(pll_core_locked, pll_core_locked_s, clk_74a);

mf_pllbase mp1 (
    .refclk         ( clk_74a ),
    .rst            ( 0 ),
    
    .outclk_0       ( clk_core_12288 ),
    .outclk_1       ( clk_core_12288_90deg ),
    
    .locked         ( pll_core_locked )
);


    
endmodule
