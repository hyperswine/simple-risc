`timescale 1ns/1ps
module cascade_tb;
 reg clk=0;always #5 clk=~clk;
 reg reset=1,acc=0;reg[53:0] a=0;wire[54:0] caso;
 GSR GSR(.GSRI(1'b1));
 ALU54D #(.OUT_REG(1),.ALUD_MODE(0),.ALU_RESET_MODE("SYNC")) alu(
 .A(a),.B(54'b0),.CASI(55'b0),.ACCLOAD(acc),.ASIGN(1'b0),.BSIGN(1'b0),
 .CE(1'b1),.CLK(clk),.RESET(reset),.DOUT(),.CASO(caso));
 initial begin
  repeat(2)@(negedge clk);reset=0;a={54{1'b1}};
  @(negedge clk);if(caso!=={1'b0,{54{1'b1}}})$fatal(1,"load");acc=1;a=1;
  @(negedge clk);if(caso!=={1'b1,54'd0})$fatal(1,"overflow");
  @(negedge clk);if(caso!=={1'b1,54'd1})$fatal(1,"cascade state");
  $display("PASS: CASO[54] remains high after overflow; it is not a carry pulse");$finish;
 end
endmodule
