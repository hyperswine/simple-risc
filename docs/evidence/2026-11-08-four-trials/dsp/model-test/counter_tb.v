`timescale 1ns/1ps
module counter_tb;
 reg clk=0;always #5 clk=~clk;
 reg reset=1,increment=1,w=0,h=0;reg[31:0] value=0;
 wire[31:0] lo,hi;wire carry;
 GSR GSR(.GSRI(1'b1));
 dsp_counter dut(clk,reset,1'b1,increment,w,h,value,lo,hi,carry);
 reg[31:0] ref_lo=0,ref_hi=0;reg ref_carry=0;
 reg[32:0] sum;integer i,checks=0,seed=32'h12345678;
 always @(posedge clk)begin
  if(reset)begin ref_lo=0;ref_hi=0;ref_carry=0;end
  else begin
   if(w && h)ref_hi=value;else ref_hi=ref_hi+ref_carry;
   if(w)begin if(!h)ref_lo=value;ref_carry=0;end
   else begin sum={1'b0,ref_lo}+increment;ref_lo=sum[31:0];ref_carry=sum[32];end
  end
  #1;
  if({lo,hi,carry} !== {ref_lo,ref_hi,ref_carry})$fatal(1,"mismatch check=%0d got=%h/%h/%b expected=%h/%h/%b",checks,lo,hi,carry,ref_lo,ref_hi,ref_carry);
  checks=checks+1;
 end
 task drive(input rr,ii,ww,hh,input[31:0] vv);
 begin @(negedge clk);reset=rr;increment=ii;w=ww;h=hh;value=vv;end endtask
 initial begin
  repeat(3)@(negedge clk);
  drive(0,1,1,1,32'hffffffff);drive(0,1,1,0,32'hffffffff);
  drive(0,1,0,0,0);drive(0,0,0,0,0); // low overflow and delayed high wrap
  drive(0,1,1,0,32'hffffffff);drive(0,1,0,0,0);drive(0,1,1,0,32'h12345678); // drain carry on low write
  drive(0,1,1,0,32'hffffffff);drive(0,1,0,0,0);drive(0,1,1,1,32'h87654321); // high write replaces carry
  for(i=0;i<10000;i=i+1)begin
   seed={seed[30:0],seed[31]^seed[21]^seed[1]^seed[0]};
   drive(i%509==0,seed[0],seed[3:1]==0,seed[4],i%17==0 ? 32'hffffffff:seed);
  end
  drive(0,1,0,0,0);@(negedge clk);$display("PASS: DSP counter %0d checks",checks);$finish;
 end
endmodule
