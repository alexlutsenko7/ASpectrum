//=============================================================================
// zx_system -- the ZX Spectrum 128 without clocks/PLLs and pin buffers
//
//   clk  112 MHz system clock: SDRAM controller, ROM loader, CPU + bus, AY,
//        keyboard, audio
//   pclk pixel clock (25 or 27 MHz, mode50 selects the timing): video
//
// After reset the ROM loader copies the ROMs from flash to SDRAM, then the
// CPU starts. Holding KEY1 while the CPU starts selects DiagROM.
//=============================================================================
`default_nettype none

module zx_system #(
    parameter integer CLK_MHZ   = 112,
    parameter integer FLASH_DIV = 4
)(
    input  wire        clk,
    input  wire        rst_n,           // synchronous to clk (released after the PLL locked)
    input  wire        pclk,
    input  wire        prst_n,
    input  wire        mode50,          // video mode (static while prst_n = 1)

    // board / adapter inputs (asynchronous)
    input  wire        key1_n,
    input  wire        turbo_n,
    input  wire        tape_in,
    input  wire        kbd_rx,
    input  wire [4:0]  joy_n,           // fire, up, down, left, right (active low)

    // SDRAM pins (the top level does the DQ tri-state)
    output wire        sd_cke,
    output wire        sd_cs_n,
    output wire        sd_ras_n,
    output wire        sd_cas_n,
    output wire        sd_we_n,
    output wire [1:0]  sd_ba,
    output wire [12:0] sd_a,
    output wire [1:0]  sd_dqm,
    output wire [15:0] sd_dq_o,
    output wire        sd_dq_oe,
    input  wire [15:0] sd_dq_i,

    // flash (flash_if)
    output wire        f_dclk,
    output wire        f_ncs,
    output wire        f_mosi,
    input  wire        f_miso,

    // VGA
    output wire        vga_r,
    output wire        vga_r_low,
    output wire        vga_g,
    output wire        vga_g_low,
    output wire        vga_b,
    output wire        vga_b_low,
    output wire        vga_hs,
    output wire        vga_vs,

    // audio
    output wire        audio_ay,
    output wire        audio_beeper,

    output reg         led              // on = turbo; fast blink = ROMs missing in flash
);

//-----------------------------------------------------------------------------
// SDRAM controller, shared by the ROM loader (first) and the CPU bus
//-----------------------------------------------------------------------------
wire        ld_req, ld_we, ld_done, bad_image;
wire [17:0] ld_addr;
wire [7:0]  ld_din;
wire        bus_req, bus_we;
wire [17:0] bus_addr;
wire [7:0]  bus_din;
wire [7:0]  ram_dout;
wire        ram_ack, ram_ready;

sdram_ram #(.ADDR_BITS(18), .CLK_MHZ(CLK_MHZ)) u_ram (
    .clk      (clk),
    .rst_n    (rst_n),
    .req      (ld_done ? bus_req  : ld_req),
    .we       (ld_done ? bus_we   : ld_we),
    .addr     (ld_done ? bus_addr : ld_addr),
    .din      (ld_done ? bus_din  : ld_din),
    .dout     (ram_dout),
    .ack      (ram_ack),
    .ready    (ram_ready),
    .sd_cke   (sd_cke),
    .sd_cs_n  (sd_cs_n),
    .sd_ras_n (sd_ras_n),
    .sd_cas_n (sd_cas_n),
    .sd_we_n  (sd_we_n),
    .sd_ba    (sd_ba),
    .sd_a     (sd_a),
    .sd_dqm   (sd_dqm),
    .sd_dq_o  (sd_dq_o),
    .sd_dq_oe (sd_dq_oe),
    .sd_dq_i  (sd_dq_i)
);

rom_loader #(.DIV(FLASH_DIV)) u_loader (
    .clk       (clk),
    .rst_n     (rst_n),
    .f_dclk    (f_dclk),
    .f_ncs     (f_ncs),
    .f_mosi    (f_mosi),
    .f_miso    (f_miso),
    .sd_req    (ld_req),
    .sd_we     (ld_we),
    .sd_addr   (ld_addr),
    .sd_din    (ld_din),
    .sd_ack    (ram_ack & !ld_done),
    .done      (ld_done),
    .bad_image (bad_image)
);

//-----------------------------------------------------------------------------
// Keyboard, AY
//-----------------------------------------------------------------------------
wire [39:0] kb_rows;

zx_keyboard #(.CLK_HZ(CLK_MHZ * 1000000)) u_kbd (
    .clk   (clk),
    .rst_n (rst_n),
    .rx    (kbd_rx),
    .rows  (kb_rows)
);

// AY clock enable: 3.5469 MHz (jt49 divides by 2 -> 1.7734 MHz, as the 128), independent of turbo
reg  [31:0] ay_dds;
reg         ay_cen;
wire [32:0] ay_next = {1'b0, ay_dds} + 33'd136016246;
always @(posedge clk) begin
    ay_dds <= ay_next[31:0];
    ay_cen <= ay_next[32];
end

wire        ay_bdir, ay_bc1;
wire [7:0]  ay_din, ay_dout;
wire [9:0]  ay_sound;

jt49_bus u_ay (
    .rst_n   (rst_n),
    .clk     (clk),
    .clk_en  (ay_cen),
    .bdir    (ay_bdir),
    .bc1     (ay_bc1),
    .din     (ay_din),
    .sel     (1'b0),
    .dout    (ay_dout),
    .sound   (ay_sound),
    .A       (),
    .B       (),
    .C       (),
    .sample  (),
    .IOA_in  (8'hFF),
    .IOA_out (),
    .IOB_in  (8'hFF),
    .IOB_out ()
);

sd_dac #(.W(10)) u_dac (
    .clk   (clk),
    .rst_n (rst_n),
    .din   (ay_sound),
    .dout  (audio_ay)
);

//-----------------------------------------------------------------------------
// CPU, bus, ports
//-----------------------------------------------------------------------------
wire        sh_we, sh_page7, screen7, beeper, diag_rom, cpu_running;
wire [12:0] sh_addr;
wire [7:0]  sh_data;
wire [2:0]  border;

zx_bus u_bus (
    .clk         (clk),
    .rst_n       (rst_n),
    .run         (ld_done),
    .turbo       (!turbo_n),
    .diag_key    (!key1_n),
    .vid50       (mode50),
    .vsync_n     (vga_vs),
    .kb_rows     (kb_rows),
    .joy         (~joy_n),
    .tape_in     (tape_in),
    .sd_req      (bus_req),
    .sd_we       (bus_we),
    .sd_addr     (bus_addr),
    .sd_din      (bus_din),
    .sd_dout     (ram_dout),
    .sd_ack      (ram_ack & ld_done),
    .sh_we       (sh_we),
    .sh_page7    (sh_page7),
    .sh_addr     (sh_addr),
    .sh_data     (sh_data),
    .ay_bdir     (ay_bdir),
    .ay_bc1      (ay_bc1),
    .ay_din      (ay_din),
    .ay_dout     (ay_dout),
    .border      (border),
    .screen7     (screen7),
    .beeper      (beeper),
    .diag_rom    (diag_rom),
    .cpu_running (cpu_running)
);

assign audio_beeper = beeper;

//-----------------------------------------------------------------------------
// Video
//-----------------------------------------------------------------------------
zx_video u_video (
    .pclk      (pclk),
    .prst_n    (prst_n),
    .mode50    (mode50),
    .border    (border),
    .screen7   (screen7),
    .wclk      (clk),
    .sh_we     (sh_we),
    .sh_page7  (sh_page7),
    .sh_addr   (sh_addr),
    .sh_data   (sh_data),
    .vga_r     (vga_r),
    .vga_r_low (vga_r_low),
    .vga_g     (vga_g),
    .vga_g_low (vga_g_low),
    .vga_b     (vga_b),
    .vga_b_low (vga_b_low),
    .vga_hs    (vga_hs),
    .vga_vs    (vga_vs)
);

//-----------------------------------------------------------------------------
// LED (active low): on = turbo, fast blink = ROM image missing / unreadable
//-----------------------------------------------------------------------------
reg [22:0] blink;
reg [2:0]  turbo_s;
always @(posedge clk) begin
    blink   <= blink + 23'd1;
    turbo_s <= {turbo_s[1:0], !turbo_n};
    led     <= bad_image ? blink[22] : !turbo_s[2];
end

endmodule

`default_nettype wire
