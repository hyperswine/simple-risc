// Matches SimpleRisc.tickCounter: low carry is applied to high next cycle.
module dsp_counter(input clk,reset,enable,increment,write_valid,write_high,
 input [31:0] write_value,output [31:0] lo,output reg [31:0] hi,output carry);
 wire [53:0] result;
 wire [31:0] operand=write_valid && !write_high ? write_value:lo;
 ALU54D #(.AREG(0),.BREG(0),.ASIGN_REG(0),.BSIGN_REG(0),.ACCLOAD_REG(0),
 .OUT_REG(1),.B_ADD_SUB(0),.C_ADD_SUB(0),.ALUD_MODE(2),.ALU_RESET_MODE("SYNC")) alu(
 .A({22'b0,operand}),.B({53'b0,increment && !write_valid}),.CASI(55'b0),
 .ACCLOAD(1'b0),.ASIGN(1'b0),.BSIGN(1'b0),.CE(enable),.CLK(clk),.RESET(reset),
 .DOUT(result),.CASO());
 assign lo=result[31:0];assign carry=result[32];
 always @(posedge clk)begin
  if(reset)hi<=0;
  else if(enable && write_valid && write_high)hi<=write_value;
  else if(enable)hi<=hi+carry;
 end
endmodule
