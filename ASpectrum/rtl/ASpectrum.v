//=============================================================================
// ASpectrum -- ZX Spectrum 128K on the QMTECH Cyclone IV EP4CE15 core board
//              with the user's QM_Atrix I/O adapter (prototype fit: adapter J2
//              plugged into U8, J1 wired to U7; see docs/BOARD_PINOUT.md)
//
// Clocks: sys_pll  c0 = 112 MHz system clock, c1 = 112 MHz delayed (SDRAM clock),
//                  c2 = 56 MHz (SD tape loader, aligned with c0)
//         vga_pll  c0 = 25 MHz (640x480@60), c1 = 27 MHz (720x576@50), switched
//                  by the global clock control block (sequenced as in VGA_TEST)
//
// Controls (USB keyboard keys: see zx_keyboard.v, docs/SD_TAPE_LOADER.md):
//   KEY0 (W13)    reset (CPU, ports, ROM reload, tape loader)
//   Ctrl+Alt+Del  reset of the machine only (the tape loader keeps running)
//   F1            held while the CPU starts (power-up or after a reset): DiagROM
//   F8            swap 50/60 Hz video
//   F12 / numpad  SD card tape loader (browser on the OSD)
//   S1 (U7.22)    50/60 Hz default (high = 50 Hz; weak pull-up while unwired)
//   TURBO_N       low = 28 MHz CPU (external tape simulator); the internal SD
//                 loader switches turbo on by itself while it plays
//   LED           on = turbo; fast blink = no ROM image in flash (program the .jic)
//   KEY1 (Y13)    not used
//=============================================================================
`default_nettype none

module ASpectrum #(
    parameter         SD_PHASE_PS   = "1250",   // SDRAM clock delay (as DDR_TEST, 1339 ps achieved)
    parameter         SW_HIGH_IS_50 = 1'b1
)(
    input  wire        CLOCK_50,
    input  wire        RESET_N,
    output wire        LEDR,

    // SDRAM
    output wire [12:0] DRAM_ADDR,
    output wire [1:0]  DRAM_BA,
    output wire        DRAM_CAS_N,
    output wire        DRAM_CKE,
    output wire        DRAM_CLK,
    output wire        DRAM_CS_N,
    inout  wire [15:0] DRAM_DQ,
    output wire        DRAM_LDQM,
    output wire        DRAM_RAS_N,
    output wire        DRAM_UDQM,
    output wire        DRAM_WE_N,

    // adapter J2 on U8
    output wire        VGA_R,
    output wire        VGA_R_LOW,
    output wire        VGA_G,
    output wire        VGA_G_LOW,
    output wire        VGA_B,
    output wire        VGA_B_LOW,
    output wire        VGA_HSYNC,
    output wire        VGA_VSYNC,
    input  wire        TAPE_IN,
    input  wire        TURBO_N,
    input  wire        KBD_A,           // keyboard module J5.2 / J5.3: which one is the module's TX is
    input  wire        KBD_B,           // not confirmed -> both inputs (pulled up), RX = KBD_A & KBD_B
    input  wire [1:0]  GND_TIE,         // grounded by the adapter: inputs only

    // SD card (Adafruit MicroSD BFF on U8.7-13)
    output wire        SD_CS_N,
    output wire        SD_SCK,
    output wire        SD_MOSI,
    input  wire        SD_MISO,

    // adapter J1, wired to U7
    output wire        AUDIO_AY,
    output wire        AUDIO_BEEPER,
    input  wire        SW_50_60,
    input  wire        JOY_UP_N,
    input  wire        JOY_DOWN_N,
    input  wire        JOY_LEFT_N,
    input  wire        JOY_RIGHT_N,
    input  wire        JOY_FIRE_N
);

//-----------------------------------------------------------------------------
// System clock and reset
//-----------------------------------------------------------------------------
wire clk, clk_sd, clk56, sys_locked;

sys_pll #(.SD_PHASE_PS(SD_PHASE_PS)) u_pll (
    .inclk0 (CLOCK_50),
    .c0     (clk),
    .c1     (clk_sd),
    .c2     (clk56),
    .locked (sys_locked)
);

// por_n: power-up only (keyboard); rst_n: machine (+ KEY0, Ctrl+Alt+Del);
// rst56_n: tape loader (+ KEY0)
wire       kbd_cad, kbd_f8_tgl;
reg  [2:0] por_sr, rst_sr, rst56_sr;
reg        cad_q;
wire       key_arst_n = RESET_N & sys_locked;
wire       arst_n     = key_arst_n & !cad_q;

always @(posedge clk or negedge sys_locked)
    if (!sys_locked) por_sr <= 3'b000;
    else             por_sr <= {por_sr[1:0], 1'b1};
wire por_n = por_sr[2];

always @(posedge clk or negedge por_n)
    if (!por_n) cad_q <= 1'b0;
    else        cad_q <= kbd_cad;

always @(posedge clk or negedge arst_n)
    if (!arst_n) rst_sr <= 3'b000;
    else         rst_sr <= {rst_sr[1:0], 1'b1};
wire rst_n = rst_sr[2];

always @(posedge clk56 or negedge key_arst_n)
    if (!key_arst_n) rst56_sr <= 3'b000;
    else             rst56_sr <= {rst56_sr[1:0], 1'b1};
wire rst56_n = rst56_sr[2];

// SDRAM clock = inverted clk_sd through a DDIO output (same I/O delay as the
// command/data pins), exactly as in DDR_TEST
altddio_out #(
    .extend_oe_disable      ("OFF"),
    .intended_device_family ("Cyclone IV E"),
    .invert_output          ("OFF"),
    .lpm_hint               ("UNUSED"),
    .lpm_type               ("altddio_out"),
    .oe_reg                 ("UNREGISTERED"),
    .power_up_high          ("OFF"),
    .width                  (1)
) u_sdclk (
    .datain_h   (1'b0),
    .datain_l   (1'b1),
    .outclock   (clk_sd),
    .dataout    (DRAM_CLK),
    .aclr       (1'b0),
    .aset       (1'b0),
    .oe         (1'b1),
    .outclocken (1'b1),
    .sclr       (1'b0),
    .sset       (1'b0),
    .oe_out     ()
);

wire [15:0] dq_o;
wire        dq_oe;
assign DRAM_DQ = dq_oe ? dq_o : 16'hzzzz;

//-----------------------------------------------------------------------------
// Video clock: 25 / 27 MHz, switched from the 50 MHz domain (see VGA_TEST)
//-----------------------------------------------------------------------------
wire clk25, clk27, vga_locked;

vga_pll u_vpll (
    .inclk0 (CLOCK_50),
    .c0     (clk25),
    .c1     (clk27),
    .locked (vga_locked)
);

reg  [2:0] rst50_sr;
always @(posedge CLOCK_50 or negedge vga_locked)
    if (!vga_locked) rst50_sr <= 3'b000;
    else             rst50_sr <= {rst50_sr[1:0], 1'b1};
wire rst50_n = rst50_sr[2];

wire sw_50;
debounce u_db_sw  (.clk(CLOCK_50), .rst_n(rst50_n), .in(SW_HIGH_IS_50 ? SW_50_60 : !SW_50_60), .out(sw_50));

// F8 (keyboard, power-on reset only) toggles kbd_f8_tgl: the video mode survives resets
reg [1:0] f8_s;
always @(posedge CLOCK_50 or negedge rst50_n)
    if (!rst50_n) f8_s <= 2'b00;
    else          f8_s <= {f8_s[0], kbd_f8_tgl};

wire mode_req = sw_50 ^ f8_s[1];

localparam [1:0] S_OFF = 2'd0, S_SEL = 2'd1, S_ENA = 2'd2, S_RUN = 2'd3;
reg  [1:0] vstate;
reg  [3:0] vwait;
reg        sel, clk_ena, video_run;

always @(posedge CLOCK_50 or negedge rst50_n)
    if (!rst50_n) begin
        vstate    <= S_OFF;
        vwait     <= 4'd0;
        sel       <= 1'b0;
        clk_ena   <= 1'b0;
        video_run <= 1'b0;
    end else begin
        vwait <= vwait + 4'd1;
        case (vstate)
            S_OFF: if (&vwait) begin sel <= mode_req; vstate <= S_SEL; end
            S_SEL: if (&vwait) begin clk_ena <= 1'b1; vstate <= S_ENA; end
            S_ENA: if (&vwait) begin video_run <= 1'b1; vstate <= S_RUN; end
            S_RUN: begin
                vwait <= 4'd0;
                if (mode_req != sel) begin
                    video_run <= 1'b0;
                    clk_ena   <= 1'b0;
                    vstate    <= S_OFF;
                end
            end
        endcase
    end

wire pclk;
vga_clkmux u_clkmux (
    .clk0   (clk25),
    .clk1   (clk27),
    .sel    (sel),
    .ena    (clk_ena),
    .outclk (pclk)
);

reg [2:0] prst_sr;
always @(posedge pclk or negedge video_run)
    if (!video_run) prst_sr <= 3'b000;
    else            prst_sr <= {prst_sr[1:0], 1'b1};
wire prst_n = prst_sr[2];

//-----------------------------------------------------------------------------
// The machine
//-----------------------------------------------------------------------------
wire f_dclk, f_ncs, f_mosi, f_miso;

flash_if u_flash (
    .dclk (f_dclk),
    .ncs  (f_ncs),
    .mosi (f_mosi),
    .miso (f_miso)
);

wire led;

zx_system u_sys (
    .clk          (clk),
    .por_n        (por_n),
    .rst_n        (rst_n),
    .clk56        (clk56),
    .rst56_n      (rst56_n),
    .pclk         (pclk),
    .prst_n       (prst_n),
    .mode50       (sel),
    .turbo_n      (TURBO_N),
    .tape_in      (TAPE_IN),
    .kbd_rx       (KBD_A & KBD_B),
    .joy_n        ({JOY_FIRE_N, JOY_UP_N, JOY_DOWN_N, JOY_LEFT_N, JOY_RIGHT_N}),
    .sd_cke       (DRAM_CKE),
    .sd_cs_n      (DRAM_CS_N),
    .sd_ras_n     (DRAM_RAS_N),
    .sd_cas_n     (DRAM_CAS_N),
    .sd_we_n      (DRAM_WE_N),
    .sd_ba        (DRAM_BA),
    .sd_a         (DRAM_ADDR),
    .sd_dqm       ({DRAM_UDQM, DRAM_LDQM}),
    .sd_dq_o      (dq_o),
    .sd_dq_oe     (dq_oe),
    .sd_dq_i      (DRAM_DQ),
    .sdc_cs_n     (SD_CS_N),
    .sdc_sck      (SD_SCK),
    .sdc_mosi     (SD_MOSI),
    .sdc_miso     (SD_MISO),
    .kbd_f8_tgl   (kbd_f8_tgl),
    .kbd_cad      (kbd_cad),
    .f_dclk       (f_dclk),
    .f_ncs        (f_ncs),
    .f_mosi       (f_mosi),
    .f_miso       (f_miso),
    .vga_r        (VGA_R),
    .vga_r_low    (VGA_R_LOW),
    .vga_g        (VGA_G),
    .vga_g_low    (VGA_G_LOW),
    .vga_b        (VGA_B),
    .vga_b_low    (VGA_B_LOW),
    .vga_hs       (VGA_HSYNC),
    .vga_vs       (VGA_VSYNC),
    .audio_ay     (AUDIO_AY),
    .audio_beeper (AUDIO_BEEPER),
    .led          (led)
);

assign LEDR = led;                      // active low LED: led = 0 -> on

endmodule

//-----------------------------------------------------------------------------
// 2-FF synchroniser + ~10 ms (2^19 clocks at 50 MHz) stability filter
//-----------------------------------------------------------------------------
module debounce (
    input  wire clk,
    input  wire rst_n,
    input  wire in,
    output reg  out
);
reg [1:0]  sync;
reg [18:0] cnt;
always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
        sync <= 2'b00;
        cnt  <= 19'd0;
        out  <= 1'b0;
    end else begin
        sync <= {sync[0], in};
        if (sync[1] == out)
            cnt <= 19'd0;
        else if (&cnt)
            out <= sync[1];
        else
            cnt <= cnt + 19'd1;
    end
endmodule

`default_nettype wire
