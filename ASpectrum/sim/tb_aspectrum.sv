//=============================================================================
// tb_aspectrum -- whole machine (zx_system) with the real ROMs:
//   flash model (bit-reversed image, as in the .jic) -> ROM loader -> SDRAM
//   model (with I/O delays, as tb_ddr_test) -> T80 boots the 128K ROM.
//
//   +define+TURBO=0|1     CPU speed (default 1: 28 MHz, boots 8x faster)
//   +define+MODE50=0|1    video mode (default 0: 640x480@60, INT from the T-state counter)
//   +define+DIAG=0|1      hold F1 (USB keyboard frame) at start -> DiagROM
//   +define+RUN_MS=<ms>   simulated time after the ROM load (default 120)
//   +define+KEYS=<ms>     at <ms> after the ROM load, type DOWN, ENTER (menu -> 128 BASIC)
//   +define+TAPELOAD=\"img\" +define+TL_MS=<ms>   SD card image (sd_card_model); at <ms>: ENTER
//                         (menu -> Tape Loader), F12 (browser), ENTER (first file); then the ROM
//                         loads it through the SD tape loader. Expects border 4 at the end.
// Output: progress lines, checks, and screen.ppm (picture of the screen shadow).
//=============================================================================
`timescale 1ns/1ps

`ifndef TURBO
 `define TURBO 1
`endif
`ifndef MODE50
 `define MODE50 0
`endif
`ifndef DIAG
 `define DIAG 0
`endif
`ifndef RUN_MS
 `define RUN_MS 120
`endif

module tb_aspectrum;

localparam realtime H = 4.464;          // half period of 112 MHz; clk56 = exactly 2 x
localparam real T_CK  = 2 * H;
localparam real TCO   = 4.0;
localparam real TBACK = 0.5;
localparam real SD_SHIFT = 1.339;

reg clk = 0, clk56 = 0, pclk = 0;
always #(H) clk = ~clk;
initial begin #(H); forever begin clk56 = ~clk56; #(2 * H); end end   // rising edges aligned with clk
always #(`MODE50 ? 18.519 : 20.0) pclk = ~pclk;

reg rst_n = 0, prst_n = 0;
initial begin
    #200 rst_n = 1;
    #100 prst_n = 1;
end

reg       kbd_rx = 1;

// SDRAM pins
wire        cke, cs_n, ras_n, cas_n, we_n, dq_oe;
wire [1:0]  ba, dqm;
wire [12:0] a;
wire [15:0] dq_o;
reg  [15:0] dq_i;
wire        f_dclk, f_ncs, f_mosi, f_miso;
wire        vr, vrl, vg, vgl, vb, vbl, hs, vs, ay, beep, led;

wire        sdc_cs_n, sdc_sck, sdc_mosi, sdc_miso;

zx_system #(
    .FLASH_DIV(2), .KBD_WAIT_MS(1),
    .FW0("../fw/build/fw0.hex"), .FW1("../fw/build/fw1.hex"), .FW2("../fw/build/fw2.hex"), .FW3("../fw/build/fw3.hex"),
    .FONT_HEX("../rtl/osd_font.hex")
) u_sys (
    .clk(clk), .por_n(rst_n), .rst_n(rst_n), .clk56(clk56), .rst56_n(rst_n),
    .pclk(pclk), .prst_n(prst_n), .mode50(1'b`MODE50),
    .turbo_n(!`TURBO), .tape_in(1'b1), .kbd_rx(kbd_rx), .joy_n(5'b11111),
    .sdc_cs_n(sdc_cs_n), .sdc_sck(sdc_sck), .sdc_mosi(sdc_mosi), .sdc_miso(sdc_miso),
    .kbd_f8_tgl(), .kbd_cad(),
    .sd_cke(cke), .sd_cs_n(cs_n), .sd_ras_n(ras_n), .sd_cas_n(cas_n), .sd_we_n(we_n),
    .sd_ba(ba), .sd_a(a), .sd_dqm(dqm), .sd_dq_o(dq_o), .sd_dq_oe(dq_oe), .sd_dq_i(dq_i),
    .f_dclk(f_dclk), .f_ncs(f_ncs), .f_mosi(f_mosi), .f_miso(f_miso),
    .vga_r(vr), .vga_r_low(vrl), .vga_g(vg), .vga_g_low(vgl), .vga_b(vb), .vga_b_low(vbl),
    .vga_hs(hs), .vga_vs(vs), .audio_ay(ay), .audio_beeper(beep), .led(led)
);

`ifdef TAPELOAD
sd_card_model #(.IMAGE(`TAPELOAD)) u_card (.sck(sdc_sck), .mosi(sdc_mosi), .cs_n(sdc_cs_n), .miso(sdc_miso));
`else
assign sdc_miso = 1'b1;                                     // no card
`endif

flash_model #(.REVERSE(1)) u_flash (.dclk(f_dclk), .ncs(f_ncs), .mosi(f_mosi), .miso(f_miso));

// pins as seen by the SDRAM (transport delays, as tb_ddr_test)
reg         m_clk = 0, m_cke = 0, m_cs_n = 1, m_ras_n = 1, m_cas_n = 1, m_we_n = 1;
reg  [1:0]  m_ba = 0, m_dqm = 3;
reg  [12:0] m_a = 0;
reg  [15:0] m_dq_drv = 'z;
wire [15:0] m_dq;
always @(clk)                                         m_clk <= #(TCO + SD_SHIFT) ~clk;
always @(cke, cs_n, ras_n, cas_n, we_n, ba, a, dqm)   {m_cke, m_cs_n, m_ras_n, m_cas_n, m_we_n, m_ba, m_a, m_dqm}
                                                         <= #(TCO) {cke, cs_n, ras_n, cas_n, we_n, ba, a, dqm};
always @(dq_oe, dq_o)                                 m_dq_drv <= #(TCO) (dq_oe ? dq_o : 16'hzzzz);
assign m_dq = m_dq_drv;
always @(m_dq)                                        dq_i <= #(TBACK) m_dq;

sdram_model #(.T_CK(T_CK)) u_sdram (
    .clk(m_clk), .cke(m_cke), .cs_n(m_cs_n), .ras_n(m_ras_n), .cas_n(m_cas_n), .we_n(m_we_n),
    .ba(m_ba), .a(m_a), .dqm(m_dqm), .dq(m_dq)
);

//-----------------------------------------------------------------------------
// Helpers
//-----------------------------------------------------------------------------
reg [7:0] rom_img [0:49151];
initial $readmemh("roms.mem", rom_img);

function automatic [7:0] sd_peek(input [17:0] ad);
    logic [15:0] w;
    logic [23:0] key;
    begin
        key = {ad[11:10], 7'd0, ad[17:12], ad[9:1]};       // {bank, row, column} as in sdram_model
        w = u_sdram.mem.exists(key) ? u_sdram.mem[key] : 16'hxxxx;
        sd_peek = ad[0] ? w[15:8] : w[7:0];
    end
endfunction

integer errors = 0;

// UART byte to the keyboard input (115200 8N1)
task automatic uart_send(input [7:0] b);
    integer i;
    begin
        kbd_rx = 0; #8680;
        for (i = 0; i < 8; i++) begin kbd_rx = b[i]; #8680; end
        kbd_rx = 1; #8680;
    end
endtask
// CH9350-style frame as parsed by zx_keyboard: header 57 AB, then counted bytes
// 0..2 (here 01 88 08), 3 = modifiers, 4 = 0, 5..7 = keys, 8.. = more keys
task automatic key_frame(input [7:0] mods, input [7:0] k);
    begin
        uart_send(8'h57); uart_send(8'hAB);
        uart_send(8'h01); uart_send(8'h88); uart_send(8'h08);
        uart_send(mods);  uart_send(8'h00);
        uart_send(k); uart_send(8'h00); uart_send(8'h00); uart_send(8'h00); uart_send(8'h00); uart_send(8'h00);
    end
endtask

// Write the screen shadow as a 320x240 PPM (32 px border), Spectrum colours
task automatic dump_screen(input string fname);
    integer f, x, y, cx, zy, b, at, ink, pix, col, scr7;
    reg [7:0] bm;
    reg [23:0] rgb;
    begin
        scr7 = u_sys.u_bus.p7ffd[3];
        f = $fopen(fname, "w");
        $fwrite(f, "P3\n320 240\n255\n");
        for (y = 0; y < 240; y++) for (x = 0; x < 320; x++) begin
            if (x < 32 || x >= 288 || y < 24 || y >= 216) begin
                col = u_sys.u_bus.border; b = 0;
            end else begin
                zy = y - 24; cx = (x - 32) >> 3;
                bm = scr7 ? u_sys.u_video.sh7[{zy[7:6], zy[2:0], zy[5:3], cx[4:0]}]
                          : u_sys.u_video.sh5[{zy[7:6], zy[2:0], zy[5:3], cx[4:0]}];
                at = scr7 ? u_sys.u_video.sh7[6144 + (zy >> 3) * 32 + cx] : u_sys.u_video.sh5[6144 + (zy >> 3) * 32 + cx];
                pix = bm[7 - ((x - 32) & 7)];
                col = pix ? (at & 7) : ((at >> 3) & 7);
                b = (at >> 6) & 1;
            end
            rgb = {(col & 2) ? (b ? 8'hFF : 8'hCD) : 8'h00, (col & 4) ? (b ? 8'hFF : 8'hCD) : 8'h00, (col & 1) ? (b ? 8'hFF : 8'hCD) : 8'h00};
            $fwrite(f, "%0d %0d %0d\n", rgb[23:16], rgb[15:8], rgb[7:0]);
        end
        $fclose(f);
        $display("%t screen written to %s (screen page %0d, border %0d)", $realtime, fname, scr7 ? 7 : 5, u_sys.u_bus.border);
    end
endtask

//-----------------------------------------------------------------------------
// Monitors
//-----------------------------------------------------------------------------
longint m1_count = 0, cen_count = 0, stall_clk = 0, sd_wr = 0;
reg [15:0] last_pc = 0;
always @(posedge clk) begin
    if (u_sys.u_bus.mstart && !u_sys.u_bus.cpu_m1_n) begin m1_count++; last_pc = u_sys.u_bus.cpu_a; end
    if (u_sys.u_bus.cen) cen_count++;
    if (u_sys.u_bus.cpu_rst_n && (u_sys.u_bus.tick | u_sys.u_bus.owed) && u_sys.u_bus.since == 3 && u_sys.u_bus.stall) stall_clk++;
    // the posted-write buffer must never be overwritten
    if (u_sys.u_bus.t2_3rd && u_sys.u_bus.smp_wr2 && !u_sys.u_bus.smp_io2 && u_sys.u_bus.wb_valid) begin
        errors++; $display("%t ERROR: write buffer overrun", $realtime);
    end
end

integer ints = 0;
always @(negedge u_sys.u_bus.int_n) ints++;

reg [7:0] p7ffd_prev = 0;
always @(posedge clk) if (u_sys.u_bus.p7ffd !== p7ffd_prev) begin
    p7ffd_prev = u_sys.u_bus.p7ffd;
    $display("%t 7FFD <= %02h  (RAM %0d, screen %0d, ROM %0d, lock %0d)  PC~%04h", $realtime, p7ffd_prev,
             p7ffd_prev[2:0], p7ffd_prev[3] ? 7 : 5, p7ffd_prev[4], p7ffd_prev[5], last_pc);
end

//-----------------------------------------------------------------------------
// Run
//-----------------------------------------------------------------------------
integer i, bad;
realtime t_load;
initial begin
    $display("TURBO=%0d MODE50=%0d DIAG=%0d", `TURBO, `MODE50, `DIAG);
    if (`DIAG) begin
        #1000 key_frame(8'h00, 8'h3A);                 // F1 held from power-up
        $display("%t F1 frame sent", $realtime);
    end
    wait (u_sys.ld_done === 1'b1);
    t_load = $realtime;
    $display("%t ROM loader done, bad_image=%0d, bit-reversed image detected=%0d", $realtime,
             u_sys.u_loader.bad_image, u_sys.u_loader.reverse);
    if (u_sys.u_loader.bad_image !== 1'b0) errors++;
    bad = 0;
    for (i = 0; i < 49152; i++)
        if (sd_peek(18'h20000 + i) !== rom_img[i]) begin
            bad++;
            if (bad <= 5) $display("  SDRAM %05h = %02h, ROM image %02h", 18'h20000 + i, sd_peek(18'h20000 + i), rom_img[i]);
        end
    $display("  ROM copy in SDRAM: %0d mismatches of 49152", bad);
    if (bad) errors++;

    for (i = 1; i <= `RUN_MS; i++) begin
        #1_000_000;
        if (i % 10 == 0)
            $display("%t %0d ms: PC~%04h  M1=%0d  T-states=%0d  INTs=%0d  stall clks=%0d  border=%0d  diag=%0d  SDRAM model errors=%0d",
                     $realtime, i, last_pc, m1_count, cen_count, ints, stall_clk, u_sys.u_bus.border, u_sys.u_bus.diag_rom, u_sdram.errors);
`ifdef TAPELOAD
        if (i % 10 == 0)
            $display("%t   tape loader: on=%0d turbo=%0d marker=%0d osd=%0d/%0d card reads=%0d", $realtime,
                     u_sys.u_tape.tape_on, u_sys.u_tape.tape_turbo, u_sys.u_tape.marker,
                     u_sys.u_tape.osd_on, u_sys.u_tape.osd_full, u_card.n_read);
        if (i == `TL_MS) begin
            $display("%t ENTER (Tape Loader), F12, ENTER (first file)", $realtime);
            key_frame(8'h00, 8'h28); #5_000_000; key_frame(8'h00, 8'h00); #20_000_000;
            key_frame(8'h00, 8'h45); #5_000_000; key_frame(8'h00, 8'h00); #10_000_000;
            $display("%t browser: on=%0d full=%0d", $realtime, u_sys.u_tape.osd_on, u_sys.u_tape.osd_full);
            key_frame(8'h00, 8'h28); #5_000_000; key_frame(8'h00, 8'h00);
            $display("%t playing: on=%0d turbo=%0d", $realtime, u_sys.u_tape.tape_on, u_sys.u_tape.tape_turbo);
        end
`endif
`ifdef KEYS
        if (i == `KEYS) begin                   // menu is up: cursor down, ENTER -> "128 BASIC"
            $display("%t typing DOWN, ENTER", $realtime);
            key_frame(8'h00, 8'h51); #30_000_000; key_frame(8'h00, 8'h00); #30_000_000;
            key_frame(8'h00, 8'h28); #30_000_000; key_frame(8'h00, 8'h00);
            dump_screen("screen_menu_keys.ppm");
        end
`endif
    end
    dump_screen("screen.ppm");
    if (u_sdram.errors) errors++;
`ifdef TAPELOAD
    if (u_sys.u_bus.border !== 3'd4) begin errors++; $display("ERROR: border is %0d, expected 4 (program not loaded and run)", u_sys.u_bus.border); end
    else $display("tape load OK: the program ran (border 4, a colour the ROM loader never uses)");
`endif
    if (errors) $display("FAIL (%0d errors)", errors); else $display("DONE (no errors detected)");
    $finish;
end

endmodule
