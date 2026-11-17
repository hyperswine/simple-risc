// Simulation stand-in for sdram_burst_memory (same name and ports), so
// boards/tangnano20k/sdram/check_pipeline_rtl.py --pin-model --burst-rtl can
// run the real core, cache and clock bridge against ddr3_line_memory and a
// behavioural LiteDRAM native port: in-order commands, random cmd/wdata
// acceptance delays and random read latency, and init_done after a
// calibration delay. Its storage is the bench's own word array
// (pipeline_cpu_tb.ram), so the bench's capture check compares against the
// same memory; the SDRAM pins hold chip select low with NOP commands.
`default_nettype none
module sdram_burst_memory #(parameter FREQ=54000000)(
 input wire clk,clk_sdram,reset,req,write,input wire [20:0] address,
 input wire [31:0] wdata,input wire [3:0] mask,
 output wire ready,output wire done,output wire [31:0] rdata,
 output wire word_valid,output wire [1:0] word_index,
 output wire O_sdram_clk,O_sdram_cke,O_sdram_cs_n,O_sdram_cas_n,O_sdram_ras_n,O_sdram_wen_n,
 output wire [3:0] O_sdram_dqm,output wire [10:0] O_sdram_addr,output wire [1:0] O_sdram_ba,
 inout wire [31:0] IO_sdram_dq);
 assign O_sdram_clk=clk_sdram;assign O_sdram_cke=1;assign O_sdram_cs_n=0;assign O_sdram_cas_n=1;
 assign O_sdram_ras_n=1;assign O_sdram_wen_n=1;assign O_sdram_dqm=4'hf;assign O_sdram_addr=0;assign O_sdram_ba=0;
 assign IO_sdram_dq=32'bz;

 reg [9:0] calibration=0; wire init_done=calibration==10'h3ff;
 always @(posedge clk) if(reset)calibration<=0; else if(!init_done)calibration<=calibration+1;

 wire [23:0] cmd_addr; wire cmd_valid,cmd_we,wdata_valid,rdata_ready;
 wire [127:0] port_wdata; wire [15:0] port_we;
 reg cmd_ready=0,wdata_ready=0,rdata_valid=0; reg [127:0] port_rdata=0;
 ddr3_line_memory adapter(.clk(clk),.reset(reset),.init_done(init_done),.req(req),.write(write),
   .address(address),.wdata(wdata),.mask(mask),.ready(ready),.done(done),.rdata(rdata),
   .word_valid(word_valid),.word_index(word_index),.cmd_addr(cmd_addr),.cmd_valid(cmd_valid),
   .cmd_we(cmd_we),.cmd_ready(cmd_ready),.port_wdata(port_wdata),.port_we(port_we),
   .wdata_valid(wdata_valid),.wdata_ready(wdata_ready),.port_rdata(port_rdata),
   .rdata_valid(rdata_valid),.rdata_ready(rdata_ready));

 integer i,read_delay=0; reg read_pending=0; reg [18:0] read_line=0;
 always @(posedge clk) begin
   cmd_ready<=($random & 3)==0;
   wdata_ready<=($random & 3)==0;
   if(cmd_valid && cmd_ready && !cmd_we)begin read_pending<=1;read_line<=cmd_addr[18:0];read_delay=4+($random & 31);end
   if(wdata_valid && wdata_ready)
     for(i=0;i<16;i=i+1)if(port_we[i])pipeline_cpu_tb.ram[{cmd_addr[18:0],i[3:2]}][8*i[1:0]+:8]<=port_wdata[8*i+:8];
   rdata_valid<=0;
   if(read_pending)begin
     if(read_delay>0)read_delay=read_delay-1;
     else begin
       rdata_valid<=1;read_pending<=0;
       port_rdata<={pipeline_cpu_tb.ram[{read_line,2'd3}],pipeline_cpu_tb.ram[{read_line,2'd2}],
                    pipeline_cpu_tb.ram[{read_line,2'd1}],pipeline_cpu_tb.ram[{read_line,2'd0}]};
     end
   end
 end
endmodule
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
