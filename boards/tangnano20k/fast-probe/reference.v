`default_nettype none
module reference_lfsr(input wire clk, reset, enable, output reg [31:0] q=1);
  always @(posedge clk)
    if(reset) q<=1;
    else if(enable) q<={q[30:0],q[31]^q[21]^q[1]^q[0]};
endmodule
module reference_counter(input wire clk, reset, enable, output reg [31:0] q=0);
  always @(posedge clk)
    if(reset) q<=0;
    else if(enable) q<=q+32'd1;
endmodule
module reference_bram(input wire clk, reset, enable, output reg [31:0] q);
  reg [31:0] mem[0:1023];
  reg [9:0] address=0;
  wire [31:0] data;
  wire [9:0] rd=address-10'd1;
  reference_lfsr lfsr(clk,reset,enable,data);
  integer i;
  initial for(i=0;i<1024;i=i+1) mem[i]=0;
  always @(posedge clk) begin
    if(reset) address<=0;
    else if(enable) address<=address+10'd1;
    // Clash blockRam is enable-controlled but has no reset of its array.
    if(enable) begin
      mem[address]<=data;
      q<=mem[rd];
    end
  end
endmodule
