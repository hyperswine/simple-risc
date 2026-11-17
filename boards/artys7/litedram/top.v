// Arty S7-50 test of the standalone LiteDRAM core (litedram_core.v from
// arty_s7.yml): the core calibrates the DDR3L with its embedded CPU, then a
// self-test drives its 128-bit native port exactly as a 16-byte cache line
// refill/write-back would: 4096 lines at addresses i ^ (i << 12), spread over
// every address bit of the 256 MiB, written with a full byte mask and an
// address-derived pattern, then read back and compared.
//
// UART: the core's calibration console until the test finishes, then
// "NATIVE PASS <lines>" or "NATIVE FAIL <line>" from this module, repeating.
// LEDs: 0 calibrated, 1 calibration error, 2 test failed, 3 test passed.
`default_nettype none
module top (
    input  wire        clk100,
    input  wire        cpu_reset_n,
    input  wire        serial_rx,
    output wire        serial_tx,
    output wire        user_led0, user_led1, user_led2, user_led3,
    output wire [13:0] ddram_a,
    output wire [2:0]  ddram_ba,
    output wire        ddram_ras_n, ddram_cas_n, ddram_we_n, ddram_cs_n,
    output wire [1:0]  ddram_dm,
    inout  wire [15:0] ddram_dq,
    inout  wire [1:0]  ddram_dqs_p, ddram_dqs_n,
    output wire        ddram_clk_p, ddram_clk_n,
    output wire        ddram_cke, ddram_odt, ddram_reset_n
);
  wire        clk, rst, init_done, init_error, pll_locked, core_tx;
  reg  [23:0] cmd_addr = 0;
  reg         cmd_valid = 0, cmd_we = 0, wdata_valid = 0;
  wire        cmd_ready, wdata_ready, rdata_valid;
  wire [127:0] rdata;
  reg  [127:0] wdata = 0;

  litedram_core dram (
      .clk(clk100), .rst(~cpu_reset_n),
      .ddram_a(ddram_a), .ddram_ba(ddram_ba), .ddram_cas_n(ddram_cas_n), .ddram_cke(ddram_cke),
      .ddram_clk_n(ddram_clk_n), .ddram_clk_p(ddram_clk_p), .ddram_cs_n(ddram_cs_n), .ddram_dm(ddram_dm),
      .ddram_dq(ddram_dq), .ddram_dqs_n(ddram_dqs_n), .ddram_dqs_p(ddram_dqs_p), .ddram_odt(ddram_odt),
      .ddram_ras_n(ddram_ras_n), .ddram_reset_n(ddram_reset_n), .ddram_we_n(ddram_we_n),
      .init_done(init_done), .init_error(init_error), .pll_locked(pll_locked),
      .uart_rx(serial_rx), .uart_tx(core_tx),
      .user_clk(clk), .user_rst(rst),
      .user_port_native_0_cmd_addr(cmd_addr), .user_port_native_0_cmd_ready(cmd_ready),
      .user_port_native_0_cmd_valid(cmd_valid), .user_port_native_0_cmd_we(cmd_we),
      .user_port_native_0_rdata_data(rdata), .user_port_native_0_rdata_ready(1'b1),
      .user_port_native_0_rdata_valid(rdata_valid),
      .user_port_native_0_wdata_data(wdata), .user_port_native_0_wdata_ready(wdata_ready),
      .user_port_native_0_wdata_valid(wdata_valid), .user_port_native_0_wdata_we(16'hffff)
  );

  localparam integer LINES = 4096;
  function [23:0] line_address(input [11:0] i);
    line_address = {i, 12'h000} ^ {12'h000, i};
  endfunction
  function [127:0] pattern(input [23:0] a);
    reg [31:0] w;
    begin
      w = {8'h5a, a};
      pattern = {~w, w * 32'h9e3779b1, w ^ 32'ha5a5a5a5, w};
    end
  endfunction

  // 0 wait calibration, 1 write cmd, 2 write data, 3 read cmd, 4 read data, 5 done
  reg [2:0]  state = 0;
  reg [12:0] index = 0;
  reg        failed = 0, finished = 0;
  reg [23:0] fail_line = 0;
  always @(posedge clk) begin
    if (rst) begin
      state <= 0; index <= 0; failed <= 0; finished <= 0; cmd_valid <= 0; wdata_valid <= 0;
    end else case (state)
      0: if (init_done && !init_error) begin state <= 1; index <= 0; end
      1: begin
           cmd_addr <= line_address(index[11:0]); cmd_we <= 1; cmd_valid <= 1;
           wdata <= pattern(line_address(index[11:0])); wdata_valid <= 1;
           if (cmd_valid && cmd_ready) begin cmd_valid <= 0; state <= 2; end
         end
      2: if (wdata_valid && wdata_ready) begin
           wdata_valid <= 0;
           if (index == LINES - 1) begin index <= 0; state <= 3; end
           else begin index <= index + 1; state <= 1; end
         end
      3: begin
           cmd_addr <= line_address(index[11:0]); cmd_we <= 0; cmd_valid <= 1;
           if (cmd_valid && cmd_ready) begin cmd_valid <= 0; state <= 4; end
         end
      4: if (rdata_valid) begin
           if (rdata != pattern(cmd_addr) && !failed) begin failed <= 1; fail_line <= cmd_addr; end
           if (index == LINES - 1) begin state <= 5; finished <= 1; end
           else begin index <= index + 1; state <= 3; end
         end
      default: ;
    endcase
  end

  // Report: "NATIVE PASS 04096\r\n" or "NATIVE FAIL xxxxxx\r\n", once a second.
  reg [8*20-1:0] message = 0;
  reg [4:0]  char = 0;
  reg [26:0] pause = 0;
  reg [9:0]  tx_shift = 10'h3ff;
  reg [3:0]  tx_bits = 0;
  reg [9:0]  tx_count = 0;
  function [7:0] hex(input [3:0] v); hex = v < 10 ? "0" + v : "a" + v - 10; endfunction
  always @(posedge clk) begin
    if (!finished) begin char <= 0; pause <= 0; end
    else if (tx_bits != 0) begin
      if (tx_count != 0) tx_count <= tx_count - 1;
      else begin tx_count <= 693; tx_shift <= {1'b1, tx_shift[9:1]}; tx_bits <= tx_bits - 1; end
    end else if (char == 0 && pause != 0) pause <= pause - 1;
    else begin
      if (char == 0)
        message <= failed ? {"NATIVE FAIL ", hex(fail_line[23:20]), hex(fail_line[19:16]), hex(fail_line[15:12]),
                             hex(fail_line[11:8]), hex(fail_line[7:4]), hex(fail_line[3:0]), "\r\n"}
                          : {"NATIVE PASS  04096\r\n"};
      tx_shift <= {1'b1, (char == 0 ? (failed ? "N" : "N") : message[8*(19-char) +: 8]), 1'b0};
      tx_bits <= 10; tx_count <= 693;
      if (char == 19) begin char <= 0; pause <= 80_000_000; end else char <= char + 1;
    end
  end
  assign serial_tx = finished ? tx_shift[0] : core_tx;
  assign {user_led3, user_led2, user_led1, user_led0} = {finished & ~failed, finished & failed, init_error, init_done};
endmodule
