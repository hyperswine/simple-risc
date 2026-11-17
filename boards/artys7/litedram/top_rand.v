// Arty S7-50: random interleaved test of ddr3_line_memory over the LiteDRAM
// native port, without the CPU. An LFSR picks masked single-word writes and
// line reads over 64 lines (heavy reuse, so a read often follows a write to
// the same line), with each line spread across rows by its high address
// bits; a byte-wise shadow copy checks every word a read returns.
// UART: "RAND PASS <ops>" every second while clean, or
// "RAND FAIL <ops> <word addr> <got> <want>" once it fails (frozen).
`default_nettype none
module top (
    input  wire        clk100, cpu_reset_n, serial_rx,
    output wire        serial_tx,
    output wire        user_led0, user_led1, user_led2, user_led3,
    output wire [13:0] ddram_a, output wire [2:0] ddram_ba,
    output wire        ddram_ras_n, ddram_cas_n, ddram_we_n, ddram_cs_n,
    output wire [1:0]  ddram_dm, inout wire [15:0] ddram_dq,
    inout  wire [1:0]  ddram_dqs_p, ddram_dqs_n,
    output wire        ddram_clk_p, ddram_clk_n, ddram_cke, ddram_odt, ddram_reset_n
);
  wire clk, rst, init_done, init_error, pll_locked, core_tx;
  wire [23:0] cmd_addr; wire cmd_valid, cmd_we, cmd_ready, wdata_valid, wdata_ready, rdata_valid, rdata_ready;
  wire [127:0] port_wdata, port_rdata; wire [15:0] port_we;
  litedram_core dram (
      .clk(clk100), .rst(~cpu_reset_n),
      .ddram_a(ddram_a), .ddram_ba(ddram_ba), .ddram_cas_n(ddram_cas_n), .ddram_cke(ddram_cke),
      .ddram_clk_n(ddram_clk_n), .ddram_clk_p(ddram_clk_p), .ddram_cs_n(ddram_cs_n), .ddram_dm(ddram_dm),
      .ddram_dq(ddram_dq), .ddram_dqs_n(ddram_dqs_n), .ddram_dqs_p(ddram_dqs_p), .ddram_odt(ddram_odt),
      .ddram_ras_n(ddram_ras_n), .ddram_reset_n(ddram_reset_n), .ddram_we_n(ddram_we_n),
      .init_done(init_done), .init_error(init_error), .pll_locked(pll_locked),
      .uart_rx(serial_rx), .uart_tx(core_tx), .user_clk(clk), .user_rst(rst),
      .user_port_native_0_cmd_addr(cmd_addr), .user_port_native_0_cmd_ready(cmd_ready),
      .user_port_native_0_cmd_valid(cmd_valid), .user_port_native_0_cmd_we(cmd_we),
      .user_port_native_0_rdata_data(port_rdata), .user_port_native_0_rdata_ready(rdata_ready),
      .user_port_native_0_rdata_valid(rdata_valid),
      .user_port_native_0_wdata_data(port_wdata), .user_port_native_0_wdata_ready(wdata_ready),
      .user_port_native_0_wdata_valid(wdata_valid), .user_port_native_0_wdata_we(port_we));

  reg req = 0, write = 0; reg [20:0] address = 0; reg [31:0] wdata = 0; reg [3:0] mask = 0;
  wire ready, done, word_valid; wire [31:0] rdata; wire [1:0] word_index;
  ddr3_line_memory adapter(.clk(clk), .reset(rst), .init_done(init_done & ~init_error),
      .req(req), .write(write), .address(address), .wdata(wdata), .mask(mask),
      .ready(ready), .done(done), .rdata(rdata), .word_valid(word_valid), .word_index(word_index),
      .cmd_addr(cmd_addr), .cmd_valid(cmd_valid), .cmd_we(cmd_we), .cmd_ready(cmd_ready),
      .port_wdata(port_wdata), .port_we(port_we), .wdata_valid(wdata_valid), .wdata_ready(wdata_ready),
      .port_rdata(port_rdata), .rdata_valid(rdata_valid), .rdata_ready(rdata_ready));

  // 64 lines: word address = {line[5:3], 10'b0, line[2:0], word}; shadow index {line, word}
  reg [7:0] sh0 [0:255], sh1 [0:255], sh2 [0:255], sh3 [0:255];
  integer k; initial for (k = 0; k < 256; k = k + 1) begin sh0[k] = 0; sh1[k] = 0; sh2[k] = 0; sh3[k] = 0; end
  reg [31:0] lfsr = 32'h1;
  wire [31:0] next = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
  reg [7:0] cur = 0;            // shadow index of the current op ({line, word})
  reg [1:0] phase = 0;          // 0 clear memory, 1 issue, 2 wait
  reg [31:0] ops = 0;
  reg failed = 0; reg [20:0] fail_addr = 0; reg [31:0] fail_got = 0, fail_want = 0;
  wire [20:0] word_address = {cur[7:5], 10'b0, cur[4:2], cur[1:0]};
  wire [7:0] check_index = {cur[7:2], word_index};
  wire [31:0] want = {sh3[check_index], sh2[check_index], sh1[check_index], sh0[check_index]};
  always @(posedge clk) begin
    if (rst || !init_done || init_error) begin phase <= 0; req <= 0; cur <= 0; ops <= 0; end
    else if (!failed) case (phase)
      0: if (req) req <= 0;              // zero all 256 words first
         else if (done) begin if (cur == 255) phase <= 1; cur <= cur + 1; end
         else if (ready) begin
           req <= 1; write <= 1; address <= word_address; wdata <= 0; mask <= 4'hf;
         end
      1: if (ready) begin
           lfsr <= next; cur <= next[7:0];
           write <= next[8]; wdata <= {next[23:16], next[31:24], lfsr[15:0]};
           mask <= next[12:9] == 0 ? 4'hf : next[12:9];
           address <= {next[7:5], 10'b0, next[4:2], next[1:0]};
           req <= 1; phase <= 2;
         end
      2: begin
           req <= 0;
           if (word_valid && !write && rdata != want) begin
             failed <= 1; fail_addr <= {address[20:2], word_index}; fail_got <= rdata; fail_want <= want;
           end
           if (done) begin
             if (write) begin
               if (mask[0]) sh0[cur] <= wdata[7:0];
               if (mask[1]) sh1[cur] <= wdata[15:8];
               if (mask[2]) sh2[cur] <= wdata[23:16];
               if (mask[3]) sh3[cur] <= wdata[31:24];
             end
             ops <= ops + 1; phase <= 1;
           end
         end
      default: phase <= 1;
    endcase
  end

  // reporter: 40-character message once a second
  localparam integer LEN = 40;
  reg [8*LEN-1:0] message = 0; reg [5:0] char = 0; reg [26:0] pause = 0;
  reg [9:0] tx_shift = 10'h3ff; reg [3:0] tx_bits = 0; reg [9:0] tx_count = 0;
  function [7:0] hex(input [3:0] v); hex = v < 10 ? "0" + v : "a" + v - 10; endfunction
  function [63:0] hex8(input [31:0] v);
    hex8 = {hex(v[31:28]), hex(v[27:24]), hex(v[23:20]), hex(v[19:16]), hex(v[15:12]), hex(v[11:8]), hex(v[7:4]), hex(v[3:0])};
  endfunction
  wire report = phase != 0 || failed;
  always @(posedge clk) begin
    if (!report) begin char <= 0; pause <= 0; end
    else if (tx_bits != 0) begin
      if (tx_count != 0) tx_count <= tx_count - 1;
      else begin tx_count <= 693; tx_shift <= {1'b1, tx_shift[9:1]}; tx_bits <= tx_bits - 1; end
    end else if (char == 0 && pause != 0) pause <= pause - 1;
    else begin
      if (char == 0)
        message <= failed ? {"RF ", hex8(ops), " ", hex8({11'b0, fail_addr}), " ", hex8(fail_got), " ", hex8(fail_want), "\r\n"}
                          : {"RAND PASS ", hex8(ops), "                    \r\n"};
      tx_shift <= {1'b1, (char == 0 ? (failed ? "R" : "R") : message[8*(LEN-1-char) +: 8]), 1'b0};
      tx_bits <= 10; tx_count <= 693;
      if (char == LEN - 1) begin char <= 0; pause <= 80_000_000; end else char <= char + 1;
    end
  end
  assign serial_tx = report ? tx_shift[0] : core_tx;
  assign {user_led3, user_led2, user_led1, user_led0} = {report & ~failed, failed, init_error, init_done};
endmodule
