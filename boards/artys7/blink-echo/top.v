// Arty S7-50 bring-up: LED 0 blinks at 1 Hz from the 12 MHz oscillator, the
// USB UART (115200 8-N-1) echoes every byte it receives, and a banner is sent
// once after configuration so transmit can be checked without receive.
// LED 1 toggles per received byte; LEDs 2-3 show its low two bits.
module top(
  input  wire       CLK12MHZ,
  input  wire       uart_txd_in,   // host -> FPGA
  output wire       uart_rxd_out,  // FPGA -> host
  output wire [3:0] led
);
  localparam integer CLOCK_HZ = 12_000_000;
  localparam integer DIV      = 104;            // 12 MHz / 115200, 0.16% fast
  localparam integer HALF_DIV = DIV / 2;

  // --- blink ---------------------------------------------------------------
  reg [23:0] blink_count = 0;
  reg        blink = 0;
  always @(posedge CLK12MHZ)
    if (blink_count == CLOCK_HZ / 2 - 1) begin blink_count <= 0; blink <= ~blink; end
    else blink_count <= blink_count + 1;

  // --- receiver: two-flop synchroniser, mid-bit sampling --------------------
  reg [1:0] rx_sync = 2'b11;
  always @(posedge CLK12MHZ) rx_sync <= {rx_sync[0], uart_txd_in};
  wire rx = rx_sync[1];

  reg [7:0] rx_count = 0;
  reg [3:0] rx_bit = 0;     // 0 idle, 1 start, 2..9 data, 10 stop
  reg [7:0] rx_shift = 0;
  reg [7:0] rx_byte = 0;
  reg       rx_ready = 0;
  always @(posedge CLK12MHZ) begin
    rx_ready <= 0;
    if (rx_bit == 0) begin
      if (!rx) begin rx_bit <= 1; rx_count <= HALF_DIV; end      // falling edge
    end else if (rx_count != 0) rx_count <= rx_count - 1;
    else begin
      rx_count <= DIV - 1;
      if (rx_bit == 1) rx_bit <= rx ? 4'd0 : 4'd2;               // false start
      else if (rx_bit <= 9) begin rx_shift <= {rx, rx_shift[7:1]}; rx_bit <= rx_bit + 1; end
      else begin
        rx_bit <= 0;
        if (rx) begin rx_byte <= rx_shift; rx_ready <= 1; end     // valid stop bit
      end
    end
  end

  // --- transmitter -----------------------------------------------------------
  reg [7:0] tx_count = 0;
  reg [3:0] tx_bit = 0;     // 0 idle, else bits left including start and stop
  reg [9:0] tx_shift = 10'h3ff;
  wire      tx_idle = tx_bit == 0;
  assign uart_rxd_out = tx_shift[0];

  // one-byte queue in front of the transmitter
  reg [7:0] pending = 0;
  reg       pending_valid = 0;

  // banner, sent once ~0.2 s after configuration
  localparam integer BANNER_LEN = 20;
  reg [8*BANNER_LEN-1:0] banner = "ARTY S7 ECHO READY\r\n";
  reg [4:0]  banner_index = 0;
  reg [21:0] banner_wait = 0;
  wire       banner_go = banner_wait == 22'h3fffff;
  always @(posedge CLK12MHZ) if (!banner_go) banner_wait <= banner_wait + 1;

  reg [7:0] last_byte = 0;
  reg       byte_toggle = 0;

  always @(posedge CLK12MHZ) begin
    if (rx_ready) begin
      pending <= rx_byte; pending_valid <= 1;
      last_byte <= rx_byte; byte_toggle <= ~byte_toggle;
    end
    if (!tx_idle) begin
      if (tx_count != 0) tx_count <= tx_count - 1;
      else begin tx_count <= DIV - 1; tx_shift <= {1'b1, tx_shift[9:1]}; tx_bit <= tx_bit - 1; end
    end else if (pending_valid && !rx_ready) begin
      tx_shift <= {1'b1, pending, 1'b0}; tx_bit <= 10; tx_count <= DIV - 1; pending_valid <= 0;
    end else if (banner_go && banner_index != BANNER_LEN) begin
      tx_shift <= {1'b1, banner[8*(BANNER_LEN-1-banner_index) +: 8], 1'b0};
      tx_bit <= 10; tx_count <= DIV - 1; banner_index <= banner_index + 1;
    end
  end

  assign led = {last_byte[1:0], byte_toggle, blink};
endmodule
