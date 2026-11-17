// Self-checking test of ddr3_line_memory against a behavioural LiteDRAM
// native port with random cmd/wdata acceptance delays and read latency.
// 20000 random operations over 256 lines: masked writes and line reads,
// checked against a reference word array; protocol checks on every cycle.
`timescale 1ns/1ps
`default_nettype none
`ifndef OPS
`define OPS 20000
`endif
module ddr3_line_memory_tb;
  reg clk = 0; always #6.25 clk = ~clk;   // 80 MHz
  reg reset = 1, init_done = 0;
  reg req = 0, write = 0; reg [20:0] address = 0; reg [31:0] wdata = 0; reg [3:0] mask = 0;
  wire ready, done, word_valid; wire [31:0] rdata; wire [1:0] word_index;
  wire [23:0] cmd_addr; wire cmd_valid, cmd_we, wdata_valid, rdata_ready;
  wire [127:0] port_wdata; wire [15:0] port_we;
  reg cmd_ready = 0, wdata_ready = 0, rdata_valid = 0; reg [127:0] port_rdata = 0;

  ddr3_line_memory dut(.clk(clk), .reset(reset), .init_done(init_done), .req(req), .write(write),
    .address(address), .wdata(wdata), .mask(mask), .ready(ready), .done(done), .rdata(rdata),
    .word_valid(word_valid), .word_index(word_index), .cmd_addr(cmd_addr), .cmd_valid(cmd_valid),
    .cmd_we(cmd_we), .cmd_ready(cmd_ready), .port_wdata(port_wdata), .port_we(port_we),
    .wdata_valid(wdata_valid), .wdata_ready(wdata_ready), .port_rdata(port_rdata),
    .rdata_valid(rdata_valid), .rdata_ready(rdata_ready));

  // --- behavioural native port ------------------------------------------------
  reg [127:0] dram [0:255];
  integer i, pending_reads = 0, read_delay = 0; reg [7:0] read_line = 0;
  initial for (i = 0; i < 256; i = i + 1) dram[i] = {4{32'hdead0000 | i}};
  always @(posedge clk) begin
    cmd_ready <= ($random & 3) == 0;
    wdata_ready <= ($random & 3) == 0;
    if (cmd_valid && cmd_ready) begin
      if (cmd_addr[23:8] != 0) begin $display("FAIL: line address out of test range %h", cmd_addr); $finish; end
      if (!cmd_we) begin pending_reads = pending_reads + 1; read_line <= cmd_addr[7:0]; read_delay = 3 + ($random & 15); end
    end
    if (wdata_valid && wdata_ready)
      for (i = 0; i < 16; i = i + 1) if (port_we[i]) dram[cmd_addr[7:0]][8*i +: 8] <= port_wdata[8*i +: 8];
    rdata_valid <= 0;
    if (pending_reads > 0) begin
      if (read_delay > 0) read_delay = read_delay - 1;
      else if (rdata_ready || !rdata_valid) begin rdata_valid <= 1; port_rdata <= dram[read_line]; pending_reads = pending_reads - 1; end
    end
  end

  // --- reference model and driver ---------------------------------------------
  reg [31:0] reference [0:1023];   // 256 lines x 4 words
  initial for (i = 0; i < 1024; i = i + 1) reference[i] = 32'hdead0000 | (i >> 2);
  integer op, words_seen, dones, errors = 0, reads = 0, writes = 0;
  reg [9:0] word; reg in_flight = 0;
  function [31:0] merge(input [31:0] old, input [31:0] value, input [3:0] m);
    merge = {m[3] ? value[31:24] : old[31:24], m[2] ? value[23:16] : old[23:16],
             m[1] ? value[15:8] : old[15:8], m[0] ? value[7:0] : old[7:0]};
  endfunction
  always @(posedge clk) if (in_flight && ready) begin $display("FAIL: ready while busy"); errors = errors + 1; end
  always @(posedge clk) if (word_valid && write) begin $display("FAIL: word_valid on a write"); errors = errors + 1; end
  always @(posedge clk) if (word_valid && !write) begin
    if (word_index != words_seen[1:0]) begin $display("FAIL: word %0d out of order (%0d)", word_index, words_seen); errors = errors + 1; end
    if (rdata !== reference[{address[9:2], word_index}]) begin
      $display("FAIL: line %0d word %0d got %h expected %h", address[9:2], word_index, rdata, reference[{address[9:2], word_index}]);
      errors = errors + 1;
    end
    words_seen = words_seen + 1;
  end
  // Watchdog: no operation may take more than 500 cycles.
  integer op_cycles = 0;
  always @(posedge clk) begin
    op_cycles = in_flight ? op_cycles + 1 : 0;
    if (op_cycles > 500) begin
      $display("FAIL: op %0d stuck: write=%0d state=%0d cmd_valid=%0d wdata_valid=%0d pending=%0d",
               op, write, dut.state, cmd_valid, wdata_valid, pending_reads);
      $finish;
    end
  end
  initial begin
    repeat (5) @(posedge clk); reset = 0;
    repeat (20) @(posedge clk);
    if (ready) begin $display("FAIL: ready before init_done"); errors = errors + 1; end
    init_done = 1;
    for (op = 0; op < `OPS; op = op + 1) begin
      // inputs change on the falling edge, so the DUT samples them cleanly
      @(negedge clk); while (!ready) @(negedge clk);
      write = $random; words_seen = 0; dones = 0;
      if (write) begin
        address = $random & 21'h3ff; wdata = $random; mask = $random;
        reference[address[9:0]] = merge(reference[address[9:0]], wdata, mask);
        writes = writes + 1;
      end else begin
        address = ($random & 21'h3ff) & ~21'h3; reads = reads + 1;
      end
      req = 1; in_flight = 0;
      @(negedge clk); req = 0; in_flight = 1;
      while (!done) @(negedge clk);
      in_flight = 0;
      if (!write && words_seen != 4) begin $display("FAIL: read returned %0d words", words_seen); errors = errors + 1; end
      @(negedge clk);
      if (done) begin $display("FAIL: done pulsed twice"); errors = errors + 1; end
      if (errors > 5) begin $display("FAIL: stopping"); $finish; end
    end
    if (errors == 0) $display("PASS: %0d reads, %0d masked writes, words/order/done/ready checked", reads, writes);
    else $display("FAIL: %0d errors", errors);
    $finish;
  end
endmodule
