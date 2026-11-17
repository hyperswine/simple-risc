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
