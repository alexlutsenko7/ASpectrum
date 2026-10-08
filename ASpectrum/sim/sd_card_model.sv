//=============================================================================
// sd_card_model -- SDHC card in SPI mode (mode 0) for simulation
//
// Commands: CMD0 (CRC 0x95 checked), CMD8 (CRC 0x87 checked), CMD55/ACMD41
// (busy for ACMD41_BUSY tries), CMD58 (OCR with CCS = 1), CMD16, CMD17 (block
// address, data from the IMAGE file), CMD24 (block write into the IMAGE file:
// data token FE, 512 bytes, 2 CRC bytes, then data response 05 and 3 busy bytes).
// Responses start one byte after the command (Ncr = 1), data token after 2 more
// bytes. MISO changes 5 ns after the falling SCK edge.
//=============================================================================
`timescale 1ns/1ps

module sd_card_model #(
    parameter string IMAGE       = "card.img",
    parameter int    ACMD41_BUSY = 2
)(
    input  wire sck,
    input  wire mosi,
    input  wire cs_n,
    output reg  miso
);

int        fd;
byte       q[$];                    // bytes to send
reg  [7:0] rx, tx;
int        rx_cnt = 0, nbit = 7;
reg  [7:0] cmd [0:5];
int        cmd_len = 0;
bit        idle = 1, app = 0;
int        acmd41 = 0;
int        n_cmd = 0, n_read = 0, n_write = 0, n_crc_err = 0;
int        wstate = 0, wcnt = 0;              // 0: commands, 1: wait for FE, 2: data, 3: CRC
longint    waddr;
byte       wbuf[512];

initial begin
    fd = $fopen(IMAGE, "r+b");
    if (fd == 0) $fatal(1, "sd_card_model: cannot open %s", IMAGE);
    miso = 1'b1;
    tx   = 8'hFF;
end

task automatic r1(input [7:0] v); q.push_back(v); endtask

task automatic exec();
    logic [5:0]  c;
    logic [31:0] arg;
    int          i, ch;
    c   = cmd[0][5:0];
    arg = {cmd[1], cmd[2], cmd[3], cmd[4]};
    n_cmd++;
    q.push_back(8'hFF);                                     // Ncr
    case (c)
        0:  if (cmd[5] != 8'h95) begin n_crc_err++; r1(8'h09); end
            else begin idle = 1; app = 0; acmd41 = 0; r1(8'h01); end
        8:  if (cmd[5] != 8'h87) begin n_crc_err++; r1(8'h09); end
            else begin r1({7'd0, idle}); q.push_back(0); q.push_back(0); q.push_back({4'd0, arg[11:8]}); q.push_back(arg[7:0]); end
        55: begin app = 1; r1({7'd0, idle}); end
        41: begin
                if (app) begin
                    acmd41++;
                    if (acmd41 > ACMD41_BUSY) idle = 0;
                    r1({7'd0, idle});
                end else r1(8'h05);
            end
        58: begin r1({7'd0, idle}); q.push_back(8'hC0); q.push_back(8'hFF); q.push_back(8'h80); q.push_back(8'h00); end
        16: r1(8'h00);
        24: begin r1(8'h00); wstate = 1; waddr = longint'(arg) * 512; end
        17: begin
                n_read++;
                r1(8'h00);
                q.push_back(8'hFF); q.push_back(8'hFF);
                q.push_back(8'hFE);
                void'($fseek(fd, longint'(arg) * 512, 0));
                for (i = 0; i < 512; i++) begin
                    ch = $fgetc(fd);
                    q.push_back(ch < 0 ? 8'h00 : ch[7:0]);
                end
                q.push_back(8'h12); q.push_back(8'h34);     // CRC (not checked by the host)
            end
        default: r1({5'd0, 3'b100} | {7'd0, idle});         // illegal command
    endcase
    if (c != 55) app = 0;
endtask

task automatic got_byte(input [7:0] b);
    if (wstate == 1) begin
        if (b == 8'hFE) begin wstate = 2; wcnt = 0; end
        return;
    end
    if (wstate == 2) begin
        wbuf[wcnt++] = b;
        if (wcnt == 512) begin wstate = 3; wcnt = 0; end
        return;
    end
    if (wstate == 3) begin
        if (++wcnt == 2) begin
            void'($fseek(fd, waddr, 0));
            for (int i = 0; i < 512; i++) $fwrite(fd, "%c", wbuf[i]);
            $fflush(fd);
            n_write++;
            wstate = 0;
            q.push_back(8'h05);                     // data accepted
            q.push_back(8'h00); q.push_back(8'h00); q.push_back(8'h00);   // busy
        end
        return;
    end
    if (cmd_len == 0) begin
        if (b[7:6] == 2'b01) begin cmd[0] = b; cmd_len = 1; end
    end else begin
        cmd[cmd_len] = b;
        cmd_len++;
        if (cmd_len == 6) begin exec(); cmd_len = 0; end
    end
endtask

always @(negedge cs_n) begin
    rx_cnt = 0;
    nbit   = 7;
    cmd_len = 0;
    tx     = 8'hFF;
    miso  <= 1'b1;
end

always @(posedge cs_n) begin
    q.delete();
    miso <= #5 1'b1;
end

always @(posedge sck) if (!cs_n) begin
    rx = {rx[6:0], mosi};
    rx_cnt++;
    if (rx_cnt == 8) begin
        rx_cnt = 0;
        got_byte(rx);
        tx = q.size() ? q.pop_front() : 8'hFF;
        nbit = 7;
    end
end

always @(negedge sck) if (!cs_n) begin
    miso <= #5 tx[nbit];
    if (nbit > 0) nbit--;
end

endmodule
