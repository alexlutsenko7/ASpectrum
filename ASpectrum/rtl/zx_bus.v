//=============================================================================
// zx_bus -- ZX Spectrum 128 CPU side: clock enable, bus bridge to the SDRAM,
//           memory paging, I/O ports, interrupt
//
// Clock enable (CEN) for the T80, from a 32-bit phase accumulator at 112 MHz:
//   normal 3.5469 MHz (31-32 clocks per T-state), turbo exactly 28 MHz (every
//   4 clocks). CEN pulses are never closer than 4 clocks (the T80 multicycle).
//   A tick that cannot be given (stall) is owed and given as soon as possible.
//
// Bus bridge, per M-cycle (see docs/T80_CEN_ANALYSIS.md):
//   T1, 1st clock after CEN: latch the address and start a speculative SDRAM
//       read (A is a T80 register output, so this is a normal 1-clock path).
//   T1, 2nd clock: sample the cycle decode (IORQ/Write; combinational in the
//       T80 -> 2-clock multicycle into the smp_* registers).
//   T2, 2nd clock: sample Write/IORQ/DO; 3rd clock: post the memory write
//       (+ screen shadow write) or perform the I/O write.
//   The CEN that ends T2 (where the T80 takes the data) is held until the
//   read of this M-cycle has completed. Only in turbo can that happen.
//   Writes are posted (the CPU never waits for them); the next read waits for
//   the SDRAM to finish them first, so a read always sees earlier writes.
//
// Memory map (SDRAM byte address, 18 bits):
//   0x00000-0x1FFFF  RAM pages 0-7 (page n at n * 0x4000)
//   0x20000/0x24000  ROM 0 (128K editor) / ROM 1 (48K BASIC), 7FFD bit 4
//   0x28000          DiagROM (both ROM slots) when selected at reset
//   CPU 0000-3FFF ROM (writes ignored), 4000 page 5, 8000 page 2, C000 7FFD[2:0]
//
// I/O (partial decoding as on the real 128):
//   write A0=0          port FE: border [2:0], MIC [3], beeper [4]
//   write A15=0, A1=0   port 7FFD: RAM page [2:0], screen [3], ROM [4], lock [5]
//   write A15=1 A14=1 A1=0  AY register select (FFFD); A15=1 A14=0 A1=0  AY data (BFFD)
//   read  A0=0          keyboard (A8-A15 select rows), EAR on bit 6, bits 5/7 = 1
//   read  FFFD          AY register
//   read  A0=1 A5=0     Kempston joystick (port 1F)
//   other reads         0xFF (floating bus not emulated yet)
//
// Interrupt: 32 T-states long. Source: VGA vsync in 50 Hz video mode (a real
// 50.00 Hz frame), otherwise a counter of 70908 T-states (128K frame), which
// also follows turbo (as in the DE10-Lite reference).
//=============================================================================
`default_nettype none

module zx_bus #(
    parameter [31:0] INC_NORMAL   = 32'd136016246,   // 3.5469 MHz at 112 MHz
    parameter [31:0] INC_TURBO    = 32'd1073741824,  // 28 MHz = every 4 clocks
    parameter integer FRAME_T     = 70908,           // T-states per 128K frame
    parameter integer TAPE_HOLD   = 23               // EAR follows the tape for 2^23 clk (75 ms) after an edge
)(
    input  wire        clk,             // 112 MHz
    input  wire        rst_n,           // system reset (CPU and ports)
    input  wire        run,             // ROMs loaded: CPU may run

    input  wire        turbo,
    input  wire        diag_key,        // KEY1 pressed: DiagROM if held when the CPU starts
    input  wire        vid50,           // video in 50 Hz mode (other clock domain)
    input  wire        vsync_n,         // video vsync (other clock domain)
    input  wire [39:0] kb_rows,         // 8 rows x 5 keys, active low, row i = A(8+i)
    input  wire [4:0]  joy,             // Kempston: fire, up, down, left, right (active high)
    input  wire        tape_in,         // asynchronous

    // SDRAM port (sdram_ram protocol: req pulse, hold until ack)
    output reg         sd_req,
    output reg         sd_we,
    output reg  [17:0] sd_addr,
    output reg  [7:0]  sd_din,
    input  wire [7:0]  sd_dout,
    input  wire        sd_ack,

    // screen shadow write (pages 5 and 7, first 6912 bytes)
    output reg         sh_we,
    output reg         sh_page7,
    output reg  [12:0] sh_addr,
    output reg  [7:0]  sh_data,

    // AY-3-8912 bus (jt49_bus)
    output reg         ay_bdir,
    output reg         ay_bc1,
    output reg  [7:0]  ay_din,
    input  wire [7:0]  ay_dout,

    output reg  [2:0]  border,
    output wire        screen7,         // 7FFD bit 3
    output reg         beeper,
    output reg         diag_rom,
    output wire        cpu_running
);

//-----------------------------------------------------------------------------
// Synchronisers
//-----------------------------------------------------------------------------
reg [2:0] turbo_s, vid50_s, vsync_s, tape_s, diag_s;
always @(posedge clk) begin
    turbo_s <= {turbo_s[1:0], turbo};
    vid50_s <= {vid50_s[1:0], vid50};
    vsync_s <= {vsync_s[1:0], vsync_n};
    tape_s  <= {tape_s[1:0],  tape_in};
    diag_s  <= {diag_s[1:0],  diag_key};
end

wire cpu_rst_n = rst_n & run;
assign cpu_running = cpu_rst_n;

// DiagROM select: follows KEY1 while the CPU is held in reset, frozen when it starts
always @(posedge clk or negedge rst_n)
    if (!rst_n)          diag_rom <= 1'b0;
    else if (!run)       diag_rom <= diag_s[2];

//-----------------------------------------------------------------------------
// CPU
//-----------------------------------------------------------------------------
wire        cen;
reg         int_n;
wire [7:0]  cpu_din;
wire [15:0] cpu_a;
wire [7:0]  cpu_do;
wire [2:0]  cpu_mc, cpu_ts;
wire        cpu_iorq, cpu_noread, cpu_write, cpu_m1_n, cpu_intcycle_n, cpu_halt_n;

cpu_t80 u_cpu (
    .clk        (clk),
    .rst_n      (cpu_rst_n),
    .cen        (cen),
    .int_n      (int_n),
    .nmi_n      (1'b1),
    .din        (cpu_din),
    .a          (cpu_a),
    .dout       (cpu_do),
    .mc         (cpu_mc),
    .ts         (cpu_ts),
    .iorq       (cpu_iorq),
    .noread     (cpu_noread),
    .write      (cpu_write),
    .m1_n       (cpu_m1_n),
    .intcycle_n (cpu_intcycle_n),
    .halt_n     (cpu_halt_n)
);

//-----------------------------------------------------------------------------
// Clock enable: phase accumulator + stall
//-----------------------------------------------------------------------------
reg  [31:0] dds;
reg         tick, owed, cen_d;
reg  [1:0]  since;                      // clocks since the last cen (0 = the clock after it), saturating at 3
wire [32:0] dds_next = {1'b0, dds} + {1'b0, (turbo_s[2] ? INC_TURBO : INC_NORMAL)};
wire        stall;

assign cen = (tick | owed) & (since == 2'd3) & !stall & cpu_rst_n;

always @(posedge clk or negedge cpu_rst_n)
    if (!cpu_rst_n) begin
        dds   <= 32'd0;
        tick  <= 1'b0;
        owed  <= 1'b0;
        since <= 2'd3;
        cen_d <= 1'b0;
    end else begin
        dds   <= dds_next[31:0];
        tick  <= dds_next[32];
        owed  <= (tick | owed) & !cen;
        since <= cen ? 2'd0 : (since == 2'd3 ? 2'd3 : since + 2'd1);
        cen_d <= cen;
    end

//-----------------------------------------------------------------------------
// M-cycle tracking
//-----------------------------------------------------------------------------
reg  [2:0] ts_prev;                     // TS before the last cen
always @(posedge clk or negedge cpu_rst_n)
    if (!cpu_rst_n)  ts_prev <= 3'd0;
    else if (cen)    ts_prev <= cpu_ts;

wire mstart = cen_d && cpu_ts == 3'd1 && ts_prev != 3'd1;   // first clock of T1
wire t2_1st = cen_d && cpu_ts == 3'd2 && ts_prev != 3'd2;   // first clock of T2

reg  [15:0] a_lat;                      // address of this M-cycle
reg         inta;                       // interrupt acknowledge M1
reg         smp_io;                     // I/O cycle      (sampled 2 clocks after the T1 cen)
reg         t1_2nd, t2_2nd, t2_3rd;     // 2nd clock of T1 / T2, 3rd clock of T2 (single-clock paths)
reg         smp_wr2, smp_io2;           // Write/IORQ     (sampled 2 clocks after the T2 cen)
reg  [7:0]  smp_do;                     // data out       (sampled 2 clocks after the T2 cen)

//-----------------------------------------------------------------------------
// Paging and memory map
//-----------------------------------------------------------------------------
reg  [7:0]  p7ffd;
assign screen7 = p7ffd[3];

function [17:0] map_addr(input [15:0] a, input [7:0] pg, input diag);
    case (a[15:14])
        2'd0:    map_addr = {1'b1, (diag ? 3'd2 : {2'b00, pg[4]}), a[13:0]};
        2'd1:    map_addr = {1'b0, 3'd5,    a[13:0]};
        2'd2:    map_addr = {1'b0, 3'd2,    a[13:0]};
        default: map_addr = {1'b0, pg[2:0], a[13:0]};
    endcase
endfunction

//-----------------------------------------------------------------------------
// SDRAM access: speculative read per M-cycle, posted writes
// wb_valid = a posted write waiting to be issued (cleared when it is issued;
// it can never be refilled before that, because each M-cycle waits for its
// own read, which is issued after any earlier write).
//-----------------------------------------------------------------------------
reg         rd_pend, rd_done, op_busy, op_we;
reg         wb_valid;
reg  [17:0] wb_addr, rd_addr;
reg  [7:0]  wb_data;

wire rd_ok = rd_done | (op_busy & !op_we & sd_ack);
assign stall = (cpu_ts == 3'd2) & !rd_ok;

// Data to the CPU: interrupt vector bus = FF, I/O data, or memory
reg  [7:0] io_data;
assign cpu_din = inta ? 8'hFF : smp_io ? io_data : sd_dout;

always @(posedge clk or negedge cpu_rst_n)
    if (!cpu_rst_n) begin
        a_lat    <= 16'd0;
        inta     <= 1'b0;
        smp_io   <= 1'b0;
        t1_2nd   <= 1'b0;
        t2_2nd   <= 1'b0;
        t2_3rd   <= 1'b0;
        smp_wr2  <= 1'b0;
        smp_io2  <= 1'b0;
        smp_do   <= 8'd0;
        rd_pend  <= 1'b0;
        rd_done  <= 1'b0;
        rd_addr  <= 18'd0;
        op_busy  <= 1'b0;
        op_we    <= 1'b0;
        wb_valid <= 1'b0;
        wb_addr  <= 18'd0;
        wb_data  <= 8'd0;
        sd_req   <= 1'b0;
        sd_we    <= 1'b0;
        sd_addr  <= 18'd0;
        sd_din   <= 8'd0;
        sh_we    <= 1'b0;
        sh_page7 <= 1'b0;
        sh_addr  <= 13'd0;
        sh_data  <= 8'd0;
    end else begin
        sd_req <= 1'b0;
        sh_we  <= 1'b0;

        // T1: latch address, start the speculative read
        t1_2nd <= mstart;
        t2_2nd <= t2_1st;
        if (mstart) begin
            a_lat   <= cpu_a;
            inta    <= !cpu_intcycle_n && cpu_mc == 3'd1;
            rd_addr <= map_addr(cpu_a, p7ffd, diag_rom);
            rd_pend <= 1'b1;
            rd_done <= 1'b0;
            smp_io  <= 1'b0;
        end
        if (t1_2nd)
            smp_io <= cpu_iorq;
        if (t2_2nd) begin
            smp_wr2 <= cpu_write;
            smp_io2 <= cpu_iorq;
            smp_do  <= cpu_do;
        end
        t2_3rd <= t2_2nd;

        // T2: post the memory write (I/O writes: see the port block)
        if (t2_3rd && smp_wr2 && !smp_io2) begin
            if (a_lat[15:14] != 2'd0) begin             // ROM is write-protected
                wb_valid <= 1'b1;
                wb_addr  <= map_addr(a_lat, p7ffd, diag_rom);
                wb_data  <= smp_do;
            end
            if ((a_lat[15:14] == 2'd1 || (a_lat[15:14] == 2'd3 && (p7ffd[2:0] == 3'd5 || p7ffd[2:0] == 3'd7)))
                && a_lat[13:0] < 14'd6912) begin
                sh_we    <= 1'b1;
                sh_page7 <= a_lat[15:14] == 2'd3 && p7ffd[2:0] == 3'd7;
                sh_addr  <= a_lat[12:0];
                sh_data  <= smp_do;
            end
        end

        // SDRAM port: one access at a time, posted write first
        if (op_busy) begin
            if (sd_ack) begin
                op_busy <= 1'b0;
                if (!op_we) rd_done <= 1'b1;
            end
        end else if (wb_valid) begin
            wb_valid <= 1'b0;
            op_busy <= 1'b1;
            op_we   <= 1'b1;
            sd_req  <= 1'b1;
            sd_we   <= 1'b1;
            sd_addr <= wb_addr;
            sd_din  <= wb_data;
        end else if (rd_pend && !mstart) begin
            rd_pend <= 1'b0;
            op_busy <= 1'b1;
            op_we   <= 1'b0;
            sd_req  <= 1'b1;
            sd_we   <= 1'b0;
            sd_addr <= rd_addr;
        end
    end

//-----------------------------------------------------------------------------
// I/O ports
//-----------------------------------------------------------------------------
reg [TAPE_HOLD-1:0] tape_cnt;
reg                 tape_active, tape_prev;

// Keyboard: AND of all rows selected by a zero on A8..A15
reg [4:0] kb_and;
integer   r;
always @* begin
    kb_and = 5'b11111;
    for (r = 0; r < 8; r = r + 1)
        if (!a_lat[8 + r]) kb_and = kb_and & kb_rows[5*r +: 5];
end

wire ear = tape_active ? !tape_s[2] : beeper;

always @(posedge clk)
    if (!a_lat[0])                                   io_data <= {1'b1, ear, 1'b1, kb_and};
    else if (a_lat[15] && a_lat[14] && !a_lat[1])    io_data <= ay_dout;
    else if (!a_lat[5])                              io_data <= {3'b000, joy};
    else                                             io_data <= 8'hFF;

always @(posedge clk or negedge cpu_rst_n)
    if (!cpu_rst_n) begin
        border      <= 3'd7;
        beeper      <= 1'b0;
        p7ffd       <= 8'd0;
        ay_bdir     <= 1'b0;
        ay_bc1      <= 1'b0;
        ay_din      <= 8'd0;
        tape_cnt    <= 0;
        tape_active <= 1'b0;
        tape_prev   <= 1'b0;
    end else begin
        ay_bdir <= 1'b0;
        ay_bc1  <= 1'b0;
        if (t2_3rd && smp_wr2 && smp_io2) begin
            if (!a_lat[0]) begin
                border <= smp_do[2:0];
                beeper <= smp_do[4];
            end
            if (!a_lat[15] && !a_lat[1] && !p7ffd[5])
                p7ffd <= smp_do;
            if (a_lat[15] && !a_lat[1]) begin
                ay_bdir <= 1'b1;
                ay_bc1  <= a_lat[14];                   // FFFD: latch address, BFFD: write data
                ay_din  <= smp_do;
            end
        end

        // EAR: follow the tape input for a while after each edge, else the beeper
        tape_prev <= tape_s[2];
        if (tape_s[2] != tape_prev) begin
            tape_active <= 1'b1;
            tape_cnt    <= 0;
        end else if (&tape_cnt)
            tape_active <= 1'b0;
        else
            tape_cnt <= tape_cnt + 1'b1;
    end

//-----------------------------------------------------------------------------
// Interrupt (32 T-states)
//-----------------------------------------------------------------------------
reg [16:0] frame_t;
reg [5:0]  int_t;
reg        vs_prev;

always @(posedge clk or negedge cpu_rst_n)
    if (!cpu_rst_n) begin
        frame_t <= 17'd0;
        int_t   <= 6'd0;
        int_n   <= 1'b1;
        vs_prev <= 1'b1;
    end else begin
        vs_prev <= vsync_s[2];
        if ((vid50_s[2] && vs_prev && !vsync_s[2]) ||                  // vsync starts
            (!vid50_s[2] && cen && frame_t == FRAME_T - 1)) begin
            int_n <= 1'b0;
            int_t <= 6'd0;
        end else if (cen && !int_n) begin
            int_t <= int_t + 6'd1;
            if (int_t == 6'd31) int_n <= 1'b1;
        end
        if (cen)
            frame_t <= (frame_t == FRAME_T - 1) ? 17'd0 : frame_t + 17'd1;
    end

endmodule

`default_nettype wire
