//=============================================================================
// zx_video -- ZX Spectrum screen on VGA, with the screen shadows
//
// Pixel clock domain (25 MHz for 640x480@60, 27 MHz for 720x576@50; mode50 is
// static while running, see vga_timing / ASpectrum.v). Each Spectrum pixel is
// 2 x 2 VGA pixels; the 512 x 384 picture sits in the middle of the active area:
//   640x480: border 64 px left/right, 48 lines top/bottom
//   720x576: border 104 px left/right, 96 lines top/bottom
//
// Screen shadows: block-RAM copies of the first 6912 bytes of RAM pages 5 and
// 7, written by the CPU side (wclk) in parallel with the SDRAM, read here.
//
// Fetch per 8-pixel cell (16 VGA pixels), la = x - border + 4 (4 px ahead):
//   la[3:0] = 0: bitmap address -> 1: bitmap byte, attribute address
//   -> 2: attribute byte -> 3: both loaded for the cell that starts next clock.
//=============================================================================
`default_nettype none

module zx_video (
    input  wire        pclk,
    input  wire        prst_n,
    input  wire        mode50,

    input  wire [2:0]  border,          // CPU clock domain
    input  wire        screen7,         // CPU clock domain (7FFD bit 3)

    input  wire        wclk,            // shadow write port (CPU clock domain)
    input  wire        sh_we,
    input  wire        sh_page7,
    input  wire [12:0] sh_addr,
    input  wire [7:0]  sh_data,

    output reg         vga_r,
    output reg         vga_r_low,
    output reg         vga_g,
    output reg         vga_g_low,
    output reg         vga_b,
    output reg         vga_b_low,
    output reg         vga_hs,
    output reg         vga_vs
);

//-----------------------------------------------------------------------------
// Shadows (simple dual port, separate clocks)
//-----------------------------------------------------------------------------
reg [7:0] sh5 [0:6911];
reg [7:0] sh7 [0:6911];
reg [7:0] q5, q7;
reg [12:0] raddr;

always @(posedge wclk)
    if (sh_we) begin
        if (sh_page7) sh7[sh_addr] <= sh_data;
        else          sh5[sh_addr] <= sh_data;
    end

always @(posedge pclk) begin
    q5 <= sh5[raddr];
    q7 <= sh7[raddr];
end

//-----------------------------------------------------------------------------
// Inputs from the CPU domain
//-----------------------------------------------------------------------------
reg [2:0] border_s1, border_s2;
reg [1:0] scr_s;
always @(posedge pclk) begin
    border_s1 <= border;
    border_s2 <= border_s1;
    scr_s     <= {scr_s[0], screen7};
end
wire [7:0] q = scr_s[1] ? q7 : q5;

//-----------------------------------------------------------------------------
// Timing
//-----------------------------------------------------------------------------
wire [9:0] hcnt, vcnt, x, y, h_act, v_act;
wire       active, hsync_n, vsync_n;

vga_timing u_timing (
    .clk     (pclk),
    .rst_n   (prst_n),
    .mode_50 (mode50),
    .hcnt    (hcnt),
    .vcnt    (vcnt),
    .active  (active),
    .x       (x),
    .y       (y),
    .h_act   (h_act),
    .v_act   (v_act),
    .hsync_n (hsync_n),
    .vsync_n (vsync_n)
);

wire [9:0]  bx  = mode50 ? 10'd104 : 10'd64;
wire [9:0]  by  = mode50 ? 10'd96  : 10'd48;
wire [9:0]  rel = x - bx;               // x inside the picture
wire [9:0]  la  = x - bx + 10'd4;       // 4 pixels ahead
wire [9:0]  ry  = y - by;
wire        in_y   = active && y >= by && ry < 10'd384;
wire        in_x   = x >= bx && rel < 10'd512;
wire        la_in  = (x + 10'd4 >= bx) && la < 10'd512;
wire [7:0]  zy     = ry[8:1];
wire [4:0]  la_cx  = la[8:4];

always @* begin
    if (la[3:0] == 4'd0)
        raddr = {zy[7:6], zy[2:0], zy[5:3], la_cx};     // bitmap
    else
        raddr = {3'b110, zy[7:3], la_cx};               // attributes (0x1800 + ...)
end

//-----------------------------------------------------------------------------
// Pixel pipeline
//-----------------------------------------------------------------------------
reg [7:0] bm_next, at_next, bm, at;
reg [4:0] fcnt;
reg       flash, vs_prev;

always @(posedge pclk or negedge prst_n)
    if (!prst_n) begin
        bm_next <= 8'd0;
        at_next <= 8'd0;
        bm      <= 8'd0;
        at      <= 8'd0;
        fcnt    <= 5'd0;
        flash   <= 1'b0;
        vs_prev <= 1'b1;
    end else begin
        if (in_y && la_in) begin
            if (la[3:0] == 4'd1) bm_next <= q;
            if (la[3:0] == 4'd2) at_next <= q;
            if (la[3:0] == 4'd3) begin bm <= bm_next; at <= at_next; end
        end
        // FLASH: swap ink and paper every 16 frames
        vs_prev <= vsync_n;
        if (vs_prev && !vsync_n) begin
            fcnt <= fcnt + 5'd1;
            if (fcnt[3:0] == 4'd15) flash <= !flash;
        end
    end

wire       pix    = bm[~rel[3:1]];
wire       ink_on = pix ^ (at[7] & flash);
wire [2:0] col    = ink_on ? at[2:0] : at[5:3];        // G R B

always @(posedge pclk or negedge prst_n)
    if (!prst_n) begin
        {vga_r, vga_r_low, vga_g, vga_g_low, vga_b, vga_b_low} <= 6'd0;
        vga_hs <= 1'b1;
        vga_vs <= 1'b1;
    end else begin
        if (!active)
            {vga_r, vga_r_low, vga_g, vga_g_low, vga_b, vga_b_low} <= 6'd0;
        else if (in_y && in_x) begin
            vga_r <= col[1];  vga_r_low <= col[1] & at[6];
            vga_g <= col[2];  vga_g_low <= col[2] & at[6];
            vga_b <= col[0];  vga_b_low <= col[0] & at[6];
        end else begin
            vga_r <= border_s2[1];  vga_r_low <= 1'b0;
            vga_g <= border_s2[2];  vga_g_low <= 1'b0;
            vga_b <= border_s2[0];  vga_b_low <= 1'b0;
        end
        vga_hs <= hsync_n;
        vga_vs <= vsync_n;
    end

endmodule

`default_nettype wire
