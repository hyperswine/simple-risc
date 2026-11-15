`timescale 1ns/1ps
module tb_probe;
  reg clk=0,reset=1,enable=1;
  always #5 clk=~clk;
  wire [31:0] lfsr, counter, bram, added, ref_lfsr, ref_counter, ref_bram;
  probe_lfsr a(clk,reset,enable,lfsr);
  probe_counter b(clk,reset,enable,counter);
  probe_bram c(clk,reset,enable,bram);
  probe_bram_add d(clk,reset,enable,added);
  reference_lfsr e(clk,reset,enable,ref_lfsr);
  reference_counter f(clk,reset,enable,ref_counter);
  reference_bram g(clk,reset,enable,ref_bram);
  wire [31:0] piped;
  reg [31:0] ref_delay=0;
  probe_bram_pipe_add h(clk,reset,enable,piped);
  always @(posedge clk) if(reset) ref_delay<=0; else if(enable) ref_delay<=ref_bram;
  wire [31:0] noreset;
  reg [31:0] ref_norst=0;
  probe_bram_pipe_norst j(clk,reset,enable,noreset);
  always @(posedge clk) if(enable) ref_norst<=ref_bram;
  integer i;
  initial begin
    repeat(4) @(negedge clk);
    for(i=0;i<20000;i=i+1) begin
      reset=(i%4093==0);
      enable=(i%17>3);
      @(negedge clk);
      if(noreset !== (ref_norst+32'h13579BDF) || piped !== (ref_delay+32'h13579BDF) || lfsr !== ref_lfsr || counter !== ref_counter || bram !== ref_bram || added !== (ref_bram+32'h13579BDF))
        $fatal(1,"Mismatch cycle=%0d lfsr=%h/%h counter=%h/%h bram=%h/%h add=%h",i,lfsr,ref_lfsr,counter,ref_counter,bram,ref_bram,added);
    end
    $display("PASS 20000 cycles: Clash and independent Verilog agree through holds, resets and RAM wraps");
    $finish;
  end
endmodule
