// Timing-probe wrapper: PLL to the probe clock, a ROM streaming the frozen
// vector through the decoder's in_ready handshake, and one output pin that
// folds the decoded byte stream (and the filler taps, if any) so synthesis
// cannot trim the datapath. FILLER_BANKS adds inert shallow register banks
// to fill slices and measure what congestion alone does to the same design.
module top #(parameter FILLER_BANKS = 0, parameter ROM_LEN = 311) (
    input clk_27m, input btn_s1, output uart_tx);

  wire clk_core, pll_lock;
  // DEF_PLL is substituted by build_deflate.sh with the swept parameters.
  deflate_pll #(.FBDIV_SEL(27), .IDIV_SEL(8), .ODIV_SEL(8)) pll (
    .clk_27m(clk_27m), .clk_core(clk_core), .clk_sdram(), .pll_lock(pll_lock));

  reg [1:0] reset_sync = 2'b11;
  wire reset = reset_sync[1];
  always @(posedge clk_core) reset_sync <= {reset_sync[0], ~btn_s1 | ~pll_lock};

  // One outstanding synchronous ROM read. Data is held until accepted;
  // a new address gets a complete read cycle before its result is captured.
  reg [15:0] rom_addr = 0;
  wire [7:0] rom_dout;
  vector_rom rom (.clk(clk_core), .addr(rom_addr), .dout(rom_dout));
  reg [1:0] feed_state = 0;
  reg [7:0] input_byte = 0;
  wire input_end = rom_addr >= ROM_LEN;
  wire input_valid = feed_state == 2 && !input_end;
  wire in_ready, out_valid, done, bad;
  wire [7:0] out_byte;
  always @(posedge clk_core) begin
    if (reset) begin
      rom_addr <= 0;
      feed_state <= 0;
      input_byte <= 0;
    end else if (!input_end) begin
      case (feed_state)
        0: feed_state <= 1;
        1: begin input_byte <= rom_dout; feed_state <= 2; end
        2: if (in_ready) begin rom_addr <= rom_addr + 1; feed_state <= 0; end
      endcase
    end
  end
  deflate_inflate decoder (
    .clk(clk_core), .reset(reset), .enable(1'b1),
    .in_valid(input_valid), .in_byte(input_byte), .in_end(input_end),
    .out_ready(1'b1), .in_ready(in_ready), .out_valid(out_valid), .out_byte(out_byte),
    .done(done), .bad(bad));

  // Keep every output bit observable through one pin.
  wire obs = out_valid ^ out_byte[0] ^ out_byte[1] ^ out_byte[2] ^ out_byte[3]
           ^ out_byte[4] ^ out_byte[5] ^ out_byte[6] ^ out_byte[7] ^ done ^ bad;

  // Inert fill: shallow 24-bit accumulators, ticked from a flop, tapped so
  // the register banks cannot be optimized away.
  wire fill_tick = out_valid | in_ready;
  wire [7:0] taps;
  genvar g;
  generate
    if (FILLER_BANKS > 0) begin : fill
      reg [23:0] acc0 [0:31];
      always @(posedge clk_core) begin
        if (fill_tick)
          acc0[0] <= acc0[0] + {acc0[0][19:0], acc0[0][23:20]} ^ 24'h5bd1a3;
      end
      assign taps[0] = acc0[0][0];
    end else begin : nofill
      assign taps = 8'h00;
    end
    for (g = 1; g < 8; g = g + 1) begin : banks
      if (g < FILLER_BANKS) begin : bank
        reg [23:0] acc [0:31];
        integer j;
        always @(posedge clk_core) begin
          if (fill_tick)
            for (j = 0; j < 32; j = j + 1)
              acc[j] <= acc[j] + {acc[j][19:0], acc[j][23:20]} ^ (24'h9e3779 + g * 24'h010101 + j * 24'h002557);
        end
        assign taps[g] = acc[g % 32][g % 24];
      end else begin : nobank
        assign taps[g] = 1'b0;
      end
    end
  endgenerate

  assign uart_tx = ~(obs ^ taps[0] ^ taps[1] ^ taps[2] ^ taps[3] ^ taps[4] ^ taps[5] ^ taps[6] ^ taps[7]);
endmodule
