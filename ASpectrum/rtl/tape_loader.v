//=============================================================================
// tape_loader -- SD card TAP/TZX player: PicoRV32 + RAM + SPI + pulse player + OSD port
//
// Clock: 56 MHz (sys_pll c2), synchronous to the 112 MHz system clock (same
// PLL, edges aligned), so the crossings below are ordinary timed paths:
//   keys, cen_tgl            112 -> 56: levels / a toggle, each value held >= 2 clocks here
//   tape_on/lvl/turbo, osd_* 56 -> 112 / pixel clock: levels, synchronised by the receiver
//
// CPU: PicoRV32 (rtl/picorv32, unmodified), RV32IMC (compressed code: the firmware
// fits 32 KB with 400 folder entries), no IRQ/counters.
// Memory map:
//   0x0000_0000  RAM, RAM_WORDS x 32 bit (code, data, stack), 4 byte lanes loaded
//                from FW0..FW3 at configuration (fw/build.sh)
//   0x1000_0000  registers (fw/hw.h):
//     00 SPI_DATA  W: send a byte   R: received byte
//     04 SPI_CTRL  W: [0] card select, [15:8] half SCK period - 1   R: same + [31] busy
//     08 KEYS      R: loader keys
//     0C FIFO      W: push command  R: [9:0] used entries, [16] player idle
//     10 TAPE      W: [0] EAR from player, [1] turbo, [2] flush   R: [1:0]
//     14 OSD       W: [0] on, [1] full screen                    R: same
//     18 TIMER     R: 56 MHz counter
//     1C MARKER    R: last CMD_MARK argument executed by the player
//     20 REC       R: recorder event: [31] pending, [30] gap (no MIC edge for GAP_T),
//                     [29] edges lost, [23:0] T-states since the previous edge; reading clears it
//     24 RECCTL    W: [0] armed (hold the Spectrum while an event is unread), [1] hold the Spectrum
//                  R: T-states since the last MIC edge (saturating)
//     28 KEYRAW    R: last keyboard report {modifiers, key 1, key 2, key 3}
//   0x2000_0000  OSD text (32 x 24 bytes, write only, byte stores)
//
// Recorder (saving): MIC (port FE bit 3) edges, timed in T-states like the
// player. While armed, an unread event holds the Spectrum CPU (hold), so no
// edge is lost however long the firmware takes (SD writes, the save dialog);
// holding stops the T-states too, so the recorded timing is unaffected.
// Each access takes 2 clocks (registered RAM / register read).
//
// SPI (mode 0): SCK = 56 MHz / (2 * (div + 1)); MOSI changes after the falling
// edge; MISO is registered every clock and the value from one clock before the
// falling edge is shifted in (> half a period after the card changed it).
//
// Pulse player: commands from a 512 x 32 FIFO (fw/hal.h):
//   00: PULSE n     hold the level for n T-states, then toggle
//   01: LEVEL l, n  set the level to l, hold n T-states
//   10: DATA b, k   k+1 bits of b, MSB first; each bit = 2 pulses of len0 / len1
//       (bit 11 set: SAMPLES, each bit sets the level for len0 T-states: TZX 0x15)
//   11: [29:28] = 0 len0 <= n, 1 len1 <= n, 2 marker <= n (no time)
// T-states are counted on the CPU clock enable (cen_tgl), so the signal is
// exact at 3.5 MHz and in turbo, and SDRAM stalls stretch it with the CPU.
// Commands follow each other without gaps; zero-time commands never show on
// the line (see the player section).
//=============================================================================
`default_nettype none

module tape_loader #(
    parameter integer RAM_WORDS = 8192,                 // 32 KB, as fw/build.sh
    parameter integer GAP_T     = 8000,                 // T-states without a MIC edge = end of a block
    parameter         FW0 = "fw/build/fw0.hex",
    parameter         FW1 = "fw/build/fw1.hex",
    parameter         FW2 = "fw/build/fw2.hex",
    parameter         FW3 = "fw/build/fw3.hex"
)(
    input  wire        clk,             // 56 MHz
    input  wire        rst_n,           // synchronous to clk

    input  wire [11:0] keys,            // loader keys (system clock domain)
    input  wire [31:0] keyraw,          // last keyboard report (system clock domain)
    input  wire        cen_tgl,         // toggles on every CPU T-state (system clock domain)
    input  wire        mic,             // port FE bit 3 (system clock domain)
    output wire        hold,            // pause the Spectrum CPU

    output wire        sd_cs_n,
    output reg         sd_sck,
    output wire        sd_mosi,
    input  wire        sd_miso,         // asynchronous pin

    output reg         tape_on,         // EAR from the player
    output reg         tape_turbo,
    output reg         tape_lvl,

    output reg         osd_on,
    output reg         osd_full,
    output reg         osd_we,
    output reg  [9:0]  osd_addr,
    output reg  [7:0]  osd_data
);

localparam integer AW = $clog2(RAM_WORDS);

//-----------------------------------------------------------------------------
// CPU
//-----------------------------------------------------------------------------
wire        mem_valid, mem_instr;
wire [31:0] mem_addr, mem_wdata;
wire [3:0]  mem_wstrb;
reg         mem_ready;
wire [31:0] mem_rdata;

picorv32 #(
    .ENABLE_COUNTERS      (0),
    .ENABLE_COUNTERS64    (0),
    .ENABLE_REGS_16_31    (1),
    .ENABLE_REGS_DUALPORT (1),
    .LATCHED_MEM_RDATA    (0),
    .TWO_STAGE_SHIFT      (1),
    .BARREL_SHIFTER       (0),
    .TWO_CYCLE_COMPARE    (0),
    .TWO_CYCLE_ALU        (0),
    .COMPRESSED_ISA       (1),
    .CATCH_MISALIGN       (0),
    .CATCH_ILLINSN        (0),
    .ENABLE_PCPI          (0),
    .ENABLE_MUL           (1),
    .ENABLE_FAST_MUL      (0),
    .ENABLE_DIV           (1),
    .ENABLE_IRQ           (0),
    .ENABLE_TRACE         (0),
    .REGS_INIT_ZERO       (0),
    .PROGADDR_RESET       (32'h0000_0000),
    .STACKADDR            (RAM_WORDS * 4)
) u_cpu (
    .clk          (clk),
    .resetn       (rst_n),
    .trap         (),
    .mem_valid    (mem_valid),
    .mem_instr    (mem_instr),
    .mem_ready    (mem_ready),
    .mem_addr     (mem_addr),
    .mem_wdata    (mem_wdata),
    .mem_wstrb    (mem_wstrb),
    .mem_rdata    (mem_rdata),
    .mem_la_read  (),
    .mem_la_write (),
    .mem_la_addr  (),
    .mem_la_wdata (),
    .mem_la_wstrb (),
    .pcpi_valid   (),
    .pcpi_insn    (),
    .pcpi_rs1     (),
    .pcpi_rs2     (),
    .pcpi_wr      (1'b0),
    .pcpi_rd      (32'd0),
    .pcpi_wait    (1'b0),
    .pcpi_ready   (1'b0),
    .irq          (32'd0),
    .eoi          (),
    .trace_valid  (),
    .trace_data   ()
);

wire          access  = mem_valid && !mem_ready;
wire          sel_ram = mem_addr[31:28] == 4'h0;
wire          sel_io  = mem_addr[31:28] == 4'h1;
wire          sel_osd = mem_addr[31:28] == 4'h2;
wire          wr      = access && (mem_wstrb != 4'd0);
wire [AW-1:0] wa      = mem_addr[AW+1:2];
wire [3:0]    reg_a   = mem_addr[5:2];

//-----------------------------------------------------------------------------
// RAM: one 8-bit block RAM per byte lane (portable byte enables)
//-----------------------------------------------------------------------------
// max_depth: build each lane from 1K x 8 blocks (6 M9K for 6144 words, not 8 x 8K x 1)
(* max_depth = 1024 *) reg [7:0] ram0 [0:RAM_WORDS-1];
(* max_depth = 1024 *) reg [7:0] ram1 [0:RAM_WORDS-1];
(* max_depth = 1024 *) reg [7:0] ram2 [0:RAM_WORDS-1];
(* max_depth = 1024 *) reg [7:0] ram3 [0:RAM_WORDS-1];
reg [7:0] q0, q1, q2, q3;

initial begin
    $readmemh(FW0, ram0);
    $readmemh(FW1, ram1);
    $readmemh(FW2, ram2);
    $readmemh(FW3, ram3);
end

wire ram_wr = wr && sel_ram;
always @(posedge clk) begin
    if (ram_wr && mem_wstrb[0]) ram0[wa] <= mem_wdata[7:0];
    if (ram_wr && mem_wstrb[1]) ram1[wa] <= mem_wdata[15:8];
    if (ram_wr && mem_wstrb[2]) ram2[wa] <= mem_wdata[23:16];
    if (ram_wr && mem_wstrb[3]) ram3[wa] <= mem_wdata[31:24];
    q0 <= ram0[wa];
    q1 <= ram1[wa];
    q2 <= ram2[wa];
    q3 <= ram3[wa];
end

//-----------------------------------------------------------------------------
// Inputs from the system clock domain
//-----------------------------------------------------------------------------
reg [11:0] keys_s1, keys_s;
reg [31:0] raw_s1, raw_s;
reg [2:0] cen_s;
always @(posedge clk) begin
    keys_s1 <= keys;
    keys_s  <= keys_s1;
    raw_s1  <= keyraw;
    raw_s   <= raw_s1;
    cen_s   <= {cen_s[1:0], cen_tgl};
end
wire tick = cen_s[2] ^ cen_s[1];

//-----------------------------------------------------------------------------
// SPI master
//-----------------------------------------------------------------------------
reg [7:0] spi_div, spi_dcnt, spi_sh;
reg [2:0] spi_bit;
reg       spi_busy, spi_cs, miso_r;

assign sd_cs_n = !spi_cs;
assign sd_mosi = spi_sh[7];

always @(posedge clk) miso_r <= sd_miso;

always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
        spi_div  <= 8'd69;
        spi_dcnt <= 8'd0;
        spi_sh   <= 8'hFF;
        spi_bit  <= 3'd0;
        spi_busy <= 1'b0;
        spi_cs   <= 1'b0;
        sd_sck   <= 1'b0;
    end else begin
        if (wr && sel_io && reg_a == 4'd1) begin
            spi_cs  <= mem_wdata[0];
            spi_div <= mem_wdata[15:8];
        end
        if (wr && sel_io && reg_a == 4'd0) begin
            spi_sh   <= mem_wdata[7:0];
            spi_busy <= 1'b1;
            spi_bit  <= 3'd7;
            spi_dcnt <= spi_div;
            sd_sck   <= 1'b0;
        end else if (spi_busy) begin
            if (spi_dcnt != 8'd0)
                spi_dcnt <= spi_dcnt - 8'd1;
            else begin
                spi_dcnt <= spi_div;
                if (!sd_sck)
                    sd_sck <= 1'b1;                     // rising edge: the card samples MOSI
                else begin
                    sd_sck <= 1'b0;                     // falling edge: next bit
                    spi_sh <= {spi_sh[6:0], miso_r};
                    if (spi_bit == 3'd0) spi_busy <= 1'b0;
                    else                 spi_bit  <= spi_bit - 3'd1;
                end
            end
        end
    end

//-----------------------------------------------------------------------------
// Command FIFO (512 x 32, block RAM) with a one-command look-ahead (nxt)
//-----------------------------------------------------------------------------
reg  [31:0] fifo [0:511];
reg  [31:0] fq;
reg  [8:0]  wp, rp;
reg  [9:0]  used;
reg         loading, nxt_valid, flush;
reg  [31:0] nxt;
wire        consume;                                    // the player takes nxt this clock
wire        push  = wr && sel_io && reg_a == 4'd3 && used != 10'd512;
wire        fetch = !loading && (!nxt_valid || consume) && used != 10'd0;

always @(posedge clk) begin
    if (push) fifo[wp] <= mem_wdata;
    fq <= fifo[rp];
end

always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
        wp        <= 9'd0;
        rp        <= 9'd0;
        used      <= 10'd0;
        loading   <= 1'b0;
        nxt_valid <= 1'b0;
        nxt       <= 32'd0;
    end else if (flush) begin
        wp        <= 9'd0;
        rp        <= 9'd0;
        used      <= 10'd0;
        loading   <= 1'b0;
        nxt_valid <= 1'b0;
    end else begin
        if (push) wp <= wp + 9'd1;
        if (fetch) rp <= rp + 9'd1;
        used <= used + (push ? 10'd1 : 10'd0) - (fetch ? 10'd1 : 10'd0);
        loading <= fetch;
        if (loading) begin
            nxt       <= fq;
            nxt_valid <= 1'b1;
        end else if (consume)
            nxt_valid <= 1'b0;
    end

//-----------------------------------------------------------------------------
// Pulse player
//
// Timed commands (PULSE, LEVEL with n > 0, DATA, SAMPLES) run one at a time;
// the next one starts in the clock where the running one ends, so the line has
// no gaps. Zero-time commands (LEVEL with n = 0, LEN0/LEN1, MARK) are taken
// from nxt while a command runs and take effect exactly when it ends (level,
// marker) or when the next DATA/SAMPLES starts (lengths, latched per command).
// If the next command is not there yet when one ends (the CPU is late), the
// ticks of the gap are credited to it (pend, up to 255), so the next edge is
// still on time. After the player went idle (stop, end, flush) nothing is
// credited: the first command then starts counting from its own start.
//
// DATA b, k   (nxt[11] = 0): k+1 bits of b MSB first, each bit 2 pulses of len0 / len1
// SAMPLES b, k (nxt[11] = 1): k+1 bits of b MSB first, each sets the level for len0
//-----------------------------------------------------------------------------
localparam [1:0] K_PULSE = 2'd0, K_WAIT = 2'd1, K_DATA = 2'd2, K_SAMP = 2'd3;

reg         act_q;                      // a timed command is running
reg  [1:0]  kind;
reg  [23:0] cnt;
reg  [7:0]  dbyte;
reg  [2:0]  dbit;
reg         dhalf;
reg  [15:0] len0, len1;                 // set by LEN0 / LEN1
reg  [15:0] dl0, dl1;                   // latched by the running DATA / SAMPLES
reg  [15:0] marker, p_mark;
reg         p_mark_set, p_lvl_set, p_lvl;
reg  [7:0]  pend;                       // ticks of a gap, not yet credited
reg         credit_en;                  // a command ended and the stream goes on

wire        chain     = used != 10'd0 || loading || nxt_valid;
wire        idle      = !act_q && !chain;
wire        n_timed   = nxt[31:30] == 2'd0 || nxt[31:30] == 2'd2 || (nxt[31:30] == 2'd1 && nxt[23:0] != 24'd0);
wire        due       = act_q && (cnt == 24'd0 || (tick && cnt == 24'd1));
wire        last      = kind == K_DATA ? (dhalf && dbit == 3'd0) : kind == K_SAMP ? dbit == 3'd0 : 1'b1;
wire        ends      = due && last;
wire        absorb    = nxt_valid && !n_timed && !ends;
wire        start     = nxt_valid && n_timed && (!act_q || ends);
assign      consume   = absorb || start;

wire        lvl_end   = (kind == K_PULSE || kind == K_DATA) ? !tape_lvl : tape_lvl;
wire        lvl_after = p_lvl_set ? p_lvl : lvl_end;
wire        base      = act_q ? lvl_after : tape_lvl;     // level a new PULSE / DATA starts with
wire [8:0]  credit    = (act_q || !credit_en) ? 9'd0 : {1'b0, pend} + {8'd0, tick};
wire        is_samp   = nxt[11];
wire [23:0] n_raw     = nxt[31:30] == 2'd2 ? {8'd0, (is_samp ? len0 : (nxt[7] ? len1 : len0))} : nxt[23:0];
wire [23:0] n_eff     = n_raw > {15'd0, credit} ? n_raw - {15'd0, credit} : 24'd0;

always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
        act_q      <= 1'b0;
        kind       <= K_PULSE;
        cnt        <= 24'd0;
        dbyte      <= 8'd0;
        dbit       <= 3'd0;
        dhalf      <= 1'b0;
        len0       <= 16'd855;
        len1       <= 16'd1710;
        dl0        <= 16'd855;
        dl1        <= 16'd1710;
        marker     <= 16'd0;
        p_mark     <= 16'd0;
        p_mark_set <= 1'b0;
        p_lvl_set  <= 1'b0;
        p_lvl      <= 1'b0;
        pend       <= 8'd0;
        credit_en  <= 1'b0;
        tape_lvl   <= 1'b0;
    end else if (flush) begin
        act_q      <= 1'b0;
        pend       <= 8'd0;
        credit_en  <= 1'b0;
        marker     <= 16'd0;
        p_mark_set <= 1'b0;
        p_lvl_set  <= 1'b0;
        tape_lvl   <= 1'b0;
    end else begin
        // zero-time commands
        if (absorb) begin
            if (nxt[31:30] == 2'd1) begin
                if (act_q) begin p_lvl_set <= 1'b1; p_lvl <= nxt[24]; end
                else       tape_lvl <= nxt[24];
            end else case (nxt[29:28])
                2'd0:    len0 <= nxt[15:0];
                2'd1:    len1 <= nxt[15:0];
                2'd2:    if (act_q) begin p_mark_set <= 1'b1; p_mark <= nxt[15:0]; end
                         else       marker <= nxt[15:0];
                default: ;
            endcase
        end

        // gap credit
        if (act_q || !chain || start)
            pend <= 8'd0;
        else if (credit_en && tick && pend != 8'd255)
            pend <= pend + 8'd1;
        if (!chain && !act_q)
            credit_en <= 1'b0;

        // running command
        if (due) begin
            if (last) begin
                if (p_mark_set) marker <= p_mark;
                p_mark_set <= 1'b0;
                p_lvl_set  <= 1'b0;
                act_q      <= 1'b0;
                credit_en  <= 1'b1;
                tape_lvl   <= lvl_after;
            end else if (kind == K_DATA) begin                  // 2 pulses per bit
                tape_lvl <= !tape_lvl;
                if (!dhalf) begin
                    dhalf <= 1'b1;
                    cnt   <= dbyte[7] ? {8'd0, dl1} : {8'd0, dl0};
                end else begin
                    dhalf <= 1'b0;
                    dbit  <= dbit - 3'd1;
                    dbyte <= {dbyte[6:0], 1'b0};
                    cnt   <= dbyte[6] ? {8'd0, dl1} : {8'd0, dl0};
                end
            end else begin                                      // SAMPLES: next sample
                dbit     <= dbit - 3'd1;
                dbyte    <= {dbyte[6:0], 1'b0};
                tape_lvl <= dbyte[6];
                cnt      <= {8'd0, dl0};
            end
        end else if (act_q && tick)
            cnt <= cnt - 24'd1;

        // next timed command (in the clock the running one ends, or when idle)
        if (start) begin
            act_q <= 1'b1;
            cnt   <= n_eff;
            dbyte <= nxt[7:0];
            dbit  <= nxt[10:8];
            dhalf <= 1'b0;
            dl0   <= len0;
            dl1   <= len1;
            case (nxt[31:30])
                2'd0:    begin kind <= K_PULSE; tape_lvl <= base;    end
                2'd1:    begin kind <= K_WAIT;  tape_lvl <= nxt[24]; end
                default: begin
                    kind     <= is_samp ? K_SAMP : K_DATA;
                    tape_lvl <= is_samp ? nxt[7] : base;
                end
            endcase
        end
    end

//-----------------------------------------------------------------------------
// Recorder: MIC edges in T-states, one event at a time, Spectrum held while unread
//-----------------------------------------------------------------------------
reg  [1:0]  mic_s;
reg         mic_p, rec_pend, rec_gap, rec_ovf, gap_sent, rec_armed, rec_hold;
reg  [23:0] rec_delta;
reg  [31:0] rec_since;
wire        rd_rec   = access && !wr && sel_io && reg_a == 4'd8;
wire        mic_edge = mic_s[1] != mic_p;

assign hold = (rec_armed && rec_pend) || rec_hold;

always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
        mic_s     <= 2'b00;
        mic_p     <= 1'b0;
        rec_pend  <= 1'b0;
        rec_gap   <= 1'b0;
        rec_ovf   <= 1'b0;
        gap_sent  <= 1'b1;
        rec_delta <= 24'd0;
        rec_since <= 32'd0;
        rec_armed <= 1'b0;
        rec_hold  <= 1'b0;
    end else begin
        mic_s <= {mic_s[0], mic};
        mic_p <= mic_s[1];
        if (wr && sel_io && reg_a == 4'd9) begin
            rec_armed <= mem_wdata[0];
            rec_hold  <= mem_wdata[1];
        end
        if (rd_rec) begin
            rec_pend <= 1'b0;
            rec_ovf  <= 1'b0;
        end
        if (mic_edge) begin
            if (rec_pend && !rd_rec)
                rec_ovf <= 1'b1;                                // previous edge not read yet (not armed)
            else begin
                rec_pend  <= 1'b1;
                rec_gap   <= 1'b0;
                rec_delta <= rec_since > 32'h00FFFFFF ? 24'hFFFFFF : rec_since[23:0];
            end
            rec_since <= 32'd0;
            gap_sent  <= 1'b0;
        end else begin
            if (tick && rec_since != 32'hFFFFFFFF)
                rec_since <= rec_since + 32'd1;
            if (rec_since >= GAP_T && !gap_sent && (!rec_pend || rd_rec)) begin
                rec_pend  <= 1'b1;
                rec_gap   <= 1'b1;
                rec_delta <= GAP_T[23:0];
                gap_sent  <= 1'b1;
            end
        end
    end

//-----------------------------------------------------------------------------
// Control registers, OSD port, timer, read data
//-----------------------------------------------------------------------------
reg  [31:0] timer, io_q;
reg         rd_ram;

assign mem_rdata = rd_ram ? {q3, q2, q1, q0} : io_q;

always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
        mem_ready  <= 1'b0;
        rd_ram     <= 1'b0;
        io_q       <= 32'd0;
        timer      <= 32'd0;
        tape_on    <= 1'b0;
        tape_turbo <= 1'b0;
        flush      <= 1'b0;
        osd_on     <= 1'b0;
        osd_full   <= 1'b0;
        osd_we     <= 1'b0;
        osd_addr   <= 10'd0;
        osd_data   <= 8'd0;
    end else begin
        mem_ready <= access;
        rd_ram    <= sel_ram;
        timer     <= timer + 32'd1;
        flush     <= 1'b0;
        osd_we    <= 1'b0;

        if (wr && sel_io) begin
            if (reg_a == 4'd4) begin
                tape_on    <= mem_wdata[0];
                tape_turbo <= mem_wdata[1];
                flush      <= mem_wdata[2];
            end
            if (reg_a == 4'd5) begin
                osd_on   <= mem_wdata[0];
                osd_full <= mem_wdata[1];
            end
        end
        if (wr && sel_osd) begin
            osd_we   <= 1'b1;
            osd_data <= mem_wdata[7:0];                         // byte stores replicate the byte
            casez (mem_wstrb)
                4'b???1: osd_addr <= {mem_addr[9:2], 2'd0};
                4'b??10: osd_addr <= {mem_addr[9:2], 2'd1};
                4'b?100: osd_addr <= {mem_addr[9:2], 2'd2};
                default: osd_addr <= {mem_addr[9:2], 2'd3};
            endcase
        end

        case (reg_a)
            4'd0:    io_q <= {24'd0, spi_sh};
            4'd1:    io_q <= {spi_busy, 15'd0, spi_div, 7'd0, spi_cs};
            4'd2:    io_q <= {20'd0, keys_s};
            4'd3:    io_q <= {15'd0, idle, 6'd0, used};
            4'd4:    io_q <= {30'd0, tape_turbo, tape_on};
            4'd5:    io_q <= {30'd0, osd_full, osd_on};
            4'd6:    io_q <= timer;
            4'd7:    io_q <= {16'd0, marker};
            4'd8:    io_q <= {rec_pend, rec_gap, rec_ovf, 5'd0, rec_delta};
            4'd9:    io_q <= rec_since;
            default: io_q <= raw_s;
        endcase
    end

endmodule

`default_nettype wire
