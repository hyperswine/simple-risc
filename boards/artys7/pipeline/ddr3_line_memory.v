// The simple-risc cache's memory port (as sdram_burst_memory on the Tang
// Nano) over a LiteDRAM native port: 16-bit DDR3, burst 8, 1:4, so one native
// access is 128 bits, exactly one 16-byte cache line.
//
//   read:  a line-aligned word address; the line's four words return with
//          word_valid and word_index 0..3, then done pulses.
//   write: one 32-bit word with a 4-bit byte mask; its lane of the 128-bit
//          native write carries it, the other twelve byte enables are off;
//          done pulses once LiteDRAM has taken the data.
//
// One operation at a time (ready is low until done), and nothing is accepted
// before calibration finishes (init_done). Word i of a line is native data
// bits [32*i+31:32*i]; reads and writes use the same mapping.
// The 21-bit word address reaches the first 8 MiB of the 256 MiB.
`default_nettype none
module ddr3_line_memory (
    input  wire         clk, reset, init_done,
    input  wire         req, write,
    input  wire [20:0]  address,
    input  wire [31:0]  wdata,
    input  wire [3:0]   mask,
    output wire         ready,
    output reg          done,
    output reg  [31:0]  rdata,
    output reg          word_valid,
    output reg  [1:0]   word_index,
    // LiteDRAM native port (user_clk domain = clk)
    output reg  [23:0]  cmd_addr,
    output reg          cmd_valid,
    output reg          cmd_we,
    input  wire         cmd_ready,
    output reg  [127:0] port_wdata,
    output reg  [15:0]  port_we,
    output reg          wdata_valid,
    input  wire         wdata_ready,
    input  wire [127:0] port_rdata,
    input  wire         rdata_valid,
    output wire         rdata_ready
);
  localparam IDLE = 3'd0, READ_CMD = 3'd1, READ_DATA = 3'd2, READ_WORDS = 3'd3,
             READ_DONE = 3'd4, WRITE = 3'd5;
  reg [2:0]   state = IDLE;
  reg [127:0] line = 0;
  reg         cmd_taken = 0, data_taken = 0;
  reg [1:0]   count = 0;
  assign ready = !reset && init_done && state == IDLE;
  assign rdata_ready = state == READ_DATA;
  always @(posedge clk) begin
    done <= 0;
    word_valid <= 0;
    if (reset) begin
      state <= IDLE; cmd_valid <= 0; wdata_valid <= 0; word_index <= 0;
    end else case (state)
      IDLE: if (req && ready) begin
        cmd_addr <= {5'b0, address[20:2]};
        cmd_we <= write;
        cmd_valid <= 1;
        cmd_taken <= 0;
        data_taken <= 0;
        if (write) begin
          port_wdata <= {4{wdata}};
          port_we <= {12'b0, mask} << (4 * address[1:0]);
          wdata_valid <= 1;
          state <= WRITE;
        end else state <= READ_CMD;
      end
      READ_CMD: if (cmd_ready) begin cmd_valid <= 0; state <= READ_DATA; end
      READ_DATA: if (rdata_valid) begin line <= port_rdata; count <= 0; state <= READ_WORDS; end
      READ_WORDS: begin              // one word a cycle, in address order
        rdata <= line[32 * count +: 32];
        word_index <= count;
        word_valid <= 1;
        count <= count + 1;
        if (count == 3) state <= READ_DONE;
      end
      READ_DONE: begin done <= 1; state <= IDLE; end
      WRITE: begin
        if (cmd_valid && cmd_ready) begin cmd_valid <= 0; cmd_taken <= 1; end
        if (wdata_valid && wdata_ready) begin wdata_valid <= 0; data_taken <= 1; end
        if ((cmd_taken || (cmd_valid && cmd_ready)) && (data_taken || (wdata_valid && wdata_ready))) begin
          done <= 1; state <= IDLE;
        end
      end
      default: state <= IDLE;
    endcase
  end
endmodule
