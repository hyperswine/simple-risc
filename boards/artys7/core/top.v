// Arty S7-50 (XC7S50-1CSGA324) wrapper for the Clash-generated simple_risc
// core (block-RAM image, as boards/tangnano20k/top.v on the Tang Nano).
//
// An MMCME2_BASE turns the 12 MHz oscillator into the core clock:
//   f = 12 * MULT / DIVIDE MHz, VCO = 12 * MULT within 600-1200 MHz.
// build.sh sets MULT and DIVIDE from FREQ_MHZ. The UART runs at f / 868 baud.
// There is no microSD slot: the core's SPI port is tied off.
`default_nettype none

module top #(
    parameter integer MULT   = 63,  // VCO 756 MHz
    parameter integer DIVIDE = 14   // 54 MHz
) (
    input  wire       CLK12MHZ,
    input  wire       btn0,          // BTN0, active high: resets the core
    input  wire       uart_txd_in,   // host -> FPGA
    output wire       uart_rxd_out,  // FPGA -> host
    output wire [3:0] led
);
  wire clk_fb, clk_mmcm, clk_core, locked;
  MMCME2_BASE #(
      .CLKIN1_PERIOD   (83.333),
      .DIVCLK_DIVIDE   (1),
      .CLKFBOUT_MULT_F (MULT),
      .CLKOUT0_DIVIDE_F(DIVIDE),
      .CLKOUT0_PHASE   (0.000)
  ) mmcm (
      .CLKIN1  (CLK12MHZ),
      .CLKFBIN (clk_fb),
      .CLKFBOUT(clk_fb),
      .CLKOUT0 (clk_mmcm),
      .LOCKED  (locked),
      .PWRDWN  (1'b0),
      .RST     (1'b0)
  );
  BUFG core_clock (.I(clk_mmcm), .O(clk_core));

  // Assert reset asynchronously, release it synchronously to the core clock.
  wire reset_request = btn0 | ~locked;
  reg [1:0] reset_sync = 2'b11;
  always @(posedge clk_core or posedge reset_request)
    if (reset_request) reset_sync <= 2'b11;
    else reset_sync <= {reset_sync[0], 1'b0};

  // LED 0: heartbeat from the core clock; LED 1: core out of reset.
  reg [25:0] beat = 0;
  always @(posedge clk_core) beat <= beat + 1;
  assign led = {2'b00, ~reset_sync[1], beat[25]};

  simple_risc core (
      .clk(clk_core),
      .reset(reset_sync[1]),
      .enable(1'b1),
      .uart_rx(uart_txd_in),
      .sd_miso(1'b1),
      .uart_tx(uart_rxd_out),
      .sd_sck(),
      .sd_mosi(),
      .sd_cs()
  );
endmodule
