// simple-risc's SDRAM-pipeline core on the Arty S7-50 with DDR3L.
//
// Same core, cache and clock bridge as the Tang Nano's fprisc-81 shape
// (boards/tangnano20k/sdram/pipeline_top.v); the SDRAM controller is replaced
// by ddr3_line_memory over a standalone LiteDRAM core (../litedram).
//   CPU clock:    12 MHz oscillator -> MMCME2_BASE (12 * MULT / DIVIDE)
//   memory clock: LiteDRAM's user_clk (its PLL from the 100 MHz input)
// The CPU is held in reset until DDR3 calibration finishes.
// LEDs: 0 calibrated, 1 calibration error, 2 CPU clock locked, 3 heartbeat.
`default_nettype none
module top #(
    parameter integer MULT   = 54,   // CPU 81 MHz: VCO 648 MHz
    parameter integer DIVIDE = 8,
    parameter LINE_BITS = 11, parameter WAYS = 2,
    parameter ROM_FILE = "bootrom-sdram.hex"
) (
    input  wire        CLK12MHZ, clk100, cpu_reset_n,
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
  // --- CPU clock -------------------------------------------------------------
  wire clk_fb, clk_mmcm, clk, locked;
  MMCME2_BASE #(.CLKIN1_PERIOD(83.333), .DIVCLK_DIVIDE(1), .CLKFBOUT_MULT_F(MULT),
                .CLKOUT0_DIVIDE_F(DIVIDE), .CLKOUT0_PHASE(0.000)) mmcm (
      .CLKIN1(CLK12MHZ), .CLKFBIN(clk_fb), .CLKFBOUT(clk_fb), .CLKOUT0(clk_mmcm),
      .LOCKED(locked), .PWRDWN(1'b0), .RST(1'b0));
  BUFG cpu_clock (.I(clk_mmcm), .O(clk));

  // --- DDR3 through LiteDRAM -------------------------------------------------
  wire clk_memory, dram_rst, init_done, init_error, dram_locked;
  wire [23:0] cmd_addr; wire cmd_valid, cmd_we, cmd_ready;
  wire [127:0] port_wdata, port_rdata; wire [15:0] port_we;
  wire wdata_valid, wdata_ready, rdata_valid, rdata_ready;
  litedram_core dram (
      .clk(clk100), .rst(~cpu_reset_n),
      .ddram_a(ddram_a), .ddram_ba(ddram_ba), .ddram_cas_n(ddram_cas_n), .ddram_cke(ddram_cke),
      .ddram_clk_n(ddram_clk_n), .ddram_clk_p(ddram_clk_p), .ddram_cs_n(ddram_cs_n), .ddram_dm(ddram_dm),
      .ddram_dq(ddram_dq), .ddram_dqs_n(ddram_dqs_n), .ddram_dqs_p(ddram_dqs_p), .ddram_odt(ddram_odt),
      .ddram_ras_n(ddram_ras_n), .ddram_reset_n(ddram_reset_n), .ddram_we_n(ddram_we_n),
      .init_done(init_done), .init_error(init_error), .pll_locked(dram_locked),
      .uart_rx(1'b1), .uart_tx(),
      .user_clk(clk_memory), .user_rst(dram_rst),
      .user_port_native_0_cmd_addr(cmd_addr), .user_port_native_0_cmd_ready(cmd_ready),
      .user_port_native_0_cmd_valid(cmd_valid), .user_port_native_0_cmd_we(cmd_we),
      .user_port_native_0_rdata_data(port_rdata), .user_port_native_0_rdata_ready(rdata_ready),
      .user_port_native_0_rdata_valid(rdata_valid),
      .user_port_native_0_wdata_data(port_wdata), .user_port_native_0_wdata_ready(wdata_ready),
      .user_port_native_0_wdata_valid(wdata_valid), .user_port_native_0_wdata_we(port_we));

  // --- resets: assert asynchronously, release synchronously -----------------
  reg [1:0] init_sync = 0;   // calibration status into the CPU domain
  always @(posedge clk) init_sync <= {init_sync[0], init_done & ~init_error};
  wire reset_request = ~cpu_reset_n | ~locked;
  reg [1:0] reset_sync = 3;
  always @(posedge clk or posedge reset_request)
    if (reset_request) reset_sync <= 3; else reset_sync <= {reset_sync[0], ~init_sync[1]};
  wire reset = reset_sync[1];
  reg [1:0] memory_reset_sync = 3;
  always @(posedge clk_memory or posedge dram_rst)
    if (dram_rst) memory_reset_sync <= 3; else memory_reset_sync <= {memory_reset_sync[0], 1'b0};
  wire memory_reset = memory_reset_sync[1];

  // --- core, cache, bridge, adapter ------------------------------------------
  wire [21:0] address; wire write, hold_cpu; wire [31:0] wdata, rdata; wire [3:0] mask;
  sdram_pipeline_risc core(.clk(clk), .reset(reset), .enable(1'b1), .uart_rx(serial_rx), .uart_tx(serial_tx),
    .memory_data(rdata), .memory_hold(hold_cpu), .memory_address(address), .memory_write(write),
    .memory_wdata(wdata), .memory_mask(mask), .sd_miso(1'b1), .sd_sck(), .sd_mosi(), .sd_cs());
  wire req, mw, ready, done, word_valid; wire [20:0] ma; wire [31:0] md, mdata; wire [3:0] mm; wire [1:0] word_index;
  sdram_pipeline_cache #(.LINE_BITS(LINE_BITS), .WAYS(WAYS), .ROM_FILE(ROM_FILE)) cache(
    clk, reset, address, write, wdata, mask, hold_cpu, rdata,
    req, mw, ma, md, mm, ready, done, mdata, word_valid, word_index);
  wire memory_req, memory_write, memory_ready, memory_done, memory_word_valid;
  wire [20:0] memory_address; wire [31:0] memory_wdata, memory_rdata; wire [3:0] memory_mask; wire [1:0] memory_word_index;
  sdram_clock_bridge bridge(
    .cpu_clk(clk), .cpu_reset(reset), .cpu_req(req), .cpu_write(mw), .cpu_address(ma),
    .cpu_wdata(md), .cpu_mask(mm), .cpu_ready(ready), .cpu_done(done), .cpu_rdata(mdata),
    .cpu_word_valid(word_valid), .cpu_word_index(word_index),
    .mem_clk(clk_memory), .mem_reset(memory_reset), .mem_req(memory_req), .mem_write(memory_write),
    .mem_address(memory_address), .mem_wdata(memory_wdata), .mem_mask(memory_mask),
    .mem_ready(memory_ready), .mem_done(memory_done), .mem_rdata(memory_rdata),
    .mem_word_valid(memory_word_valid), .mem_word_index(memory_word_index));
  ddr3_line_memory memory(.clk(clk_memory), .reset(memory_reset), .init_done(init_done & ~init_error),
    .req(memory_req), .write(memory_write), .address(memory_address), .wdata(memory_wdata), .mask(memory_mask),
    .ready(memory_ready), .done(memory_done), .rdata(memory_rdata),
    .word_valid(memory_word_valid), .word_index(memory_word_index),
    .cmd_addr(cmd_addr), .cmd_valid(cmd_valid), .cmd_we(cmd_we), .cmd_ready(cmd_ready),
    .port_wdata(port_wdata), .port_we(port_we), .wdata_valid(wdata_valid), .wdata_ready(wdata_ready),
    .port_rdata(port_rdata), .rdata_valid(rdata_valid), .rdata_ready(rdata_ready));

  reg [25:0] beat = 0;
  always @(posedge clk) beat <= beat + 1;
  assign {user_led3, user_led2, user_led1, user_led0} = {beat[25], locked, init_error, init_done};
endmodule
