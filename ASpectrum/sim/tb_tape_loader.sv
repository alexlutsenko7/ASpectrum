//=============================================================================
// tb_tape_loader -- the SD tape loader alone: firmware boots, mounts the card
// image (sd_card_model), the test opens the browser, picks short.tzx and plays
// it in turbo (cen_tgl every 4 system clocks), continuing after the stop block.
// The EAR signal is captured in T-states (ticks while a command runs or a gap is credited) and
// compared with the reference timeline from fw/tools/tzxref.py.
// Then saving: a ROM-style MIC signal of `SAVE_TAP (pilots shortened to 300 pulses) is fed
// in, T-state by T-state; the T-states stop while the loader holds the CPU, as in the real
// machine. Recording is started from the browser ([Save to this folder], Enter on the
// default name SAVE0001) and stopped with F12; run_loader_sim.sh then checks the file on
// the card image with fatcheck.py.
//   +define+IMAGE="..."  +define+REF="..."  (set by run_loader_sim.sh)
//=============================================================================
`timescale 1ns/1ps

module tb_tape_loader;

localparam realtime H = 4.464;          // half period of 112 MHz; clk56 = exactly 2 x

reg clk = 0, clk56 = 0;
always #(H) clk = ~clk;
initial begin #(H); forever begin clk56 = ~clk56; #(2 * H); end end   // rising edges aligned

reg rst_n = 0;
initial #1000 rst_n = 1;

// CPU clock enable in turbo: one T-state every 4 system clocks; none while the
// loader holds the CPU (hold, synchronised as in zx_bus)
reg [1:0] cdiv = 0;
reg       cen_tgl = 0;
reg [1:0] hold_s = 0;
wire      hold;
wire      ts = cdiv == 2'd3 && !hold_s[1];             // a T-state this clock
always @(posedge clk) begin
    hold_s <= {hold_s[0], hold};
    cdiv <= cdiv + 2'd1;
    if (ts) cen_tgl <= !cen_tgl;
end

// MIC: edges after the given numbers of T-states
reg       mic = 0;
int       mic_d[$];
int       mic_cnt = 0;
always @(posedge clk) if (ts && mic_d.size()) begin
    if (mic_cnt + 1 >= mic_d[0]) begin mic <= !mic; void'(mic_d.pop_front()); mic_cnt = 0; end
    else mic_cnt++;
end
reg [31:0] keyraw = 0;
int       hold_clks = 0;
always @(posedge clk) if (hold) hold_clks++;

reg  [11:0] keys = 0;
wire       sd_cs_n, sd_sck, sd_mosi, sd_miso;
wire       tape_on, tape_turbo, tape_lvl, osd_on, osd_full, osd_we;
wire [9:0] osd_addr;
wire [7:0] osd_data;

tape_loader #(
    .FW0("../fw/build/fw0.hex"), .FW1("../fw/build/fw1.hex"),
    .FW2("../fw/build/fw2.hex"), .FW3("../fw/build/fw3.hex")
) dut (
    .clk(clk56), .rst_n(rst_n), .keys(keys), .keyraw(keyraw), .cen_tgl(cen_tgl), .mic(mic), .hold(hold),
    .sd_cs_n(sd_cs_n), .sd_sck(sd_sck), .sd_mosi(sd_mosi), .sd_miso(sd_miso),
    .tape_on(tape_on), .tape_turbo(tape_turbo), .tape_lvl(tape_lvl),
    .osd_on(osd_on), .osd_full(osd_full), .osd_we(osd_we), .osd_addr(osd_addr), .osd_data(osd_data)
);

sd_card_model #(.IMAGE(`IMAGE)) card (.sck(sd_sck), .mosi(sd_mosi), .cs_n(sd_cs_n), .miso(sd_miso));

//-----------------------------------------------------------------------------
// OSD text
//-----------------------------------------------------------------------------
reg [7:0] osd [0:1023];
initial for (int i = 0; i < 1024; i++) osd[i] = 8'h20;
always @(posedge clk56) if (osd_we) osd[osd_addr] <= osd_data;

function automatic string osd_row(input int r);
    string s = "";
    for (int c = 0; c < 32; c++) begin
        byte ch = osd[r * 32 + c] & 8'h7F;
        s = {s, string'(ch)};
    end
    return s;
endfunction

function automatic bit row_inverse(input int r);
    return osd[r * 32] [7] && osd[r * 32 + 31][7];
endfunction

task automatic show_osd(input string why);
    $display("%t OSD (%s, on=%0d full=%0d):", $realtime, why, osd_on, osd_full);
    for (int r = 0; r < 24; r++)
        if (osd_full || r == 23)
            $display("   %s|%s|", row_inverse(r) ? "*" : " ", osd_row(r));
endtask

//-----------------------------------------------------------------------------
// Keys (KEYS bits as fw/hw.h)
//-----------------------------------------------------------------------------
localparam K_MENU = 0, K_UP = 1, K_DOWN = 2, K_ENTER = 5, K_KP5 = 7, K_STOP = 10;
task automatic press(input int k);
    keys[k] = 1; #(2_000_000);
    keys[k] = 0; #(2_000_000);
endtask
// a key in the raw keyboard report (USB HID code), as the save dialog reads it
task automatic press_raw(input [7:0] code);
    keyraw = {24'd0, code}; #(2_000_000);
    keyraw = 0;             #(2_000_000);
endtask

// ROM SAVE signal for one TAP block: pilot (300 pulses here), sync, 2 pulses per bit
task automatic mic_block(input byte d[$], input int pause);
    mic_d.push_back(pause);
    repeat (300) mic_d.push_back(2168);
    mic_d.push_back(667);
    mic_d.push_back(735);
    foreach (d[i]) for (int k = 7; k >= 0; k--) begin
        mic_d.push_back(d[i][k] ? 1710 : 855);
        mic_d.push_back(d[i][k] ? 1710 : 855);
    end
endtask

//-----------------------------------------------------------------------------
// Signal capture: T-states (ticks) while the player is busy, segments per level
//-----------------------------------------------------------------------------
int      seg_l[$], seg_n[$];
longint  run = 0;
reg      lvl_prev = 0;
int      idle_on = 0;
int      on_rises = 0;
reg      on_prev = 0;
always @(posedge clk56) begin
    if (tape_on && !on_prev) on_rises++;
    on_prev <= tape_on;
end                   // idle while EAR is from the player (stop, end, underrun)
reg      idle_prev = 1;

task automatic close_seg(input int l, input longint n);
    if (n == 0) return;
    if (seg_l.size() && seg_l[$] == l) seg_n[$] = seg_n[$] + n;
    else begin seg_l.push_back(l); seg_n.push_back(n); end
endtask

always @(posedge clk56) if (rst_n) begin
    if (dut.tick && (dut.act_q || dut.credit_en)) run++;    // T-states that belong to the tape
    if (tape_lvl !== lvl_prev) begin
        close_seg(lvl_prev, run);
        run = 0;
        lvl_prev = tape_lvl;
    end
    if (tape_on && dut.idle && dut.credit_en && !idle_prev) begin   // a command ended, nothing follows
        idle_on++;
        $display("%t player ran dry (marker %0d, segments so far %0d)", $realtime, dut.marker, seg_l.size());
    end
    idle_prev = dut.idle;
end

//-----------------------------------------------------------------------------
// Run
//-----------------------------------------------------------------------------
int errors = 0;

task automatic expect_row(input int r, input string text, input bit inv);
    string got = osd_row(r);
    if (got.substr(0, text.len() - 1) != text || row_inverse(r) != inv) begin
        errors++;
        $display("ERROR: OSD row %0d is \"%s\" (inverse %0d), expected \"%s\" (inverse %0d)", r, got, row_inverse(r), text, inv);
    end
endtask

task automatic wait_tape(input bit v, input int timeout_ms);
    fork : w
        wait (tape_on === v);
        begin #(longint'(timeout_ms) * 1_000_000); errors++; $display("ERROR: timeout waiting for tape_on = %0d", v); end
    join_any
    disable w;
endtask

initial begin
    int fd, l, n, k, mism;
    $display("image %s, reference %s", `IMAGE, `REF);
    #(10_000_000);                                      // card init + mount at power-up
    $display("%t card: %0d commands, %0d sector reads, %0d CRC errors", $realtime, card.n_cmd, card.n_read, card.n_crc_err);
    if (card.n_read == 0 || card.n_crc_err) errors++;

    press(K_MENU);
    show_osd("browser");
    if (!(osd_on && osd_full)) begin errors++; $display("ERROR: browser not shown"); end
    expect_row(0, " ASpectrum tape loader", 1);
    expect_row(2, " [Save to this folder]", 0);
    expect_row(3, " Big Folder Name/", 1);
    expect_row(4, " GAMES/", 0);
    expect_row(5, " short.tzx", 0);
    press(K_DOWN);
    press(K_DOWN);
    expect_row(5, " short.tzx", 1);
    press(K_ENTER);
    if (osd_on) begin errors++; $display("ERROR: browser still open after loading"); end
    if (!tape_on || !tape_turbo) begin errors++; $display("ERROR: tape_on/turbo not set while playing"); end

    wait_tape(0, 40);                                   // the stop block
    #(3_000_000);
    show_osd("stopped");
    expect_row(23, "Tape stopped (5=go on)", 1);
    k = on_rises;
    press(K_KP5);
    if (on_rises != k + 1) begin errors++; $display("ERROR: tape did not continue"); end
    wait_tape(0, 40);                                   // end of the tape
    if (tape_turbo) begin errors++; $display("ERROR: turbo still on at the end"); end
    #(1_000_000);

    // compare with the reference
    close_seg(lvl_prev, run);
    fd = $fopen("work_loader/got.txt", "w");
    foreach (seg_l[i]) $fdisplay(fd, "%0d %0d", seg_l[i], seg_n[i]);
    $fclose(fd);
    fd = $fopen(`REF, "r");
    if (fd == 0) $fatal(1, "cannot open %s", `REF);
    k = 0; mism = 0;
    while ($fscanf(fd, "%d %d\n", l, n) == 2) begin
        if (k >= seg_l.size() || seg_l[k] != l || seg_n[k] != n) begin
            if (mism < 5) $display("ERROR: segment %0d: reference %0d x %0d, got %0d x %0d", k, l, n,
                                   k < seg_l.size() ? seg_l[k] : -1, k < seg_n.size() ? seg_n[k] : -1);
            mism++;
        end
        k++;
    end
    $fclose(fd);
    if (k != seg_l.size()) begin
        $display("ERROR: %0d reference segments, %0d captured", k, seg_l.size()); mism++;
    end
    $display("signal: %0d segments compared, %0d mismatches; player ran dry %0d times (expected 2: stop, end)",
             k, mism, idle_on);
    if (mism) errors++;
    if (idle_on != 2) errors++;

    // Stop (F7 / keypad *): play the file again, stop it during the lead-in
    press(K_MENU);
    expect_row(5, " short.tzx", 1);                     // the browser remembers the file
    keys[K_ENTER] = 1; #(2_000_000); keys[K_ENTER] = 0; #(1_000_000);
    if (!tape_on || !tape_turbo) begin errors++; $display("ERROR: second play did not start"); end
    press(K_STOP);
    if (tape_on || tape_turbo || osd_on) begin
        errors++; $display("ERROR: after Stop: tape_on=%0d turbo=%0d osd_on=%0d (expected all 0)", tape_on, tape_turbo, osd_on);
    end else $display("%t Stop: tape, turbo and OSD off", $realtime);

    // ---- saving ----------------------------------------------------------
    begin
        int fd2, n2, pos, len;
        byte tap[$], blk[$];
        fd2 = $fopen(`SAVE_TAP, "rb");
        if (fd2 == 0) $fatal(1, "cannot open %s", `SAVE_TAP);
        while (!$feof(fd2)) begin n2 = $fgetc(fd2); if (n2 >= 0) tap.push_back(byte'(n2)); end
        $fclose(fd2);
        press(K_MENU);
        repeat (4) press(K_UP);
        expect_row(2, " [Save to this folder]", 1);
        press(K_ENTER);
        show_osd("name");
        expect_row(3, " Name: SAVE0001_.TAP", 0);
        press_raw(8'h28);                               // Enter: start recording
        #(2_000_000);
        show_osd("recording");
        if (osd_full) begin errors++; $display("ERROR: browser still open while recording"); end
        expect_row(23, "Rec SAVE0001.TAP: 0 F12=stop", 1);
        if (!dut.rec_armed) begin errors++; $display("ERROR: recorder not armed"); end
        pos = 0;
        while (pos + 2 <= tap.size()) begin
            len = {tap[pos + 1], tap[pos]};
            blk.delete();
            for (int i = 0; i < len; i++) blk.push_back(tap[pos + 2 + i]);
            mic_block(blk, pos == 0 ? 2000 : 100000);
            pos += 2 + len;
        end
        $display("%t saving: %0d MIC edges queued", $realtime, mic_d.size());
        fork : wait_mic
            wait (mic_d.size() == 0);
            begin #(400_000_000); errors++; $display("ERROR: MIC signal not consumed (%0d edges left)", mic_d.size()); end
        join_any
        disable wait_mic;
        #(3_000_000);                                   // the gap event ends the last block
        show_osd("recorded");
        expect_row(23, "Rec SAVE0001.TAP: 2 F12=stop", 1);
        press(K_MENU);                                  // F12: stop recording
        #(2_000_000);
        show_osd("saved");
        expect_row(23, "Saved SAVE0001.TAP (2 blocks)", 1);
        if (dut.rec_ovf) begin errors++; $display("ERROR: recorder lost edges"); end
        if (dut.rec_armed || tape_turbo) begin errors++; $display("ERROR: recorder/turbo still on after F12"); end
        $display("%t hold was active for %0d clocks (CPU waited for the loader)", $realtime, hold_clks);
        // F6: speed toggle message
        press(11);
        expect_row(23, "Speed: normal", 1);
        press(11);
        expect_row(23, "Speed: turbo", 1);
        $display("%t card writes: %0d", $realtime, card.n_write);
        if (card.n_write == 0) errors++;
    end
    if (errors) $display("FAIL (%0d errors)", errors); else $display("PASS (simulation; card image checked next)");
    $finish;
end

endmodule
