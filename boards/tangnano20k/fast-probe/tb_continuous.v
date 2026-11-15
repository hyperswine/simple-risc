`timescale 1ns/1fs
module probe_pll #(parameter FBDIV_SEL=23, IDIV_SEL=2, ODIV_SEL=4)
(input wire clk_27m, output reg clk_core=0, output wire clk_sdram, output reg pll_lock=0);
  localparam real HALF_PERIOD=18.5185185*(IDIV_SEL+1)/(FBDIV_SEL+1);
  always #(HALF_PERIOD) clk_core=~clk_core;
  assign clk_sdram=clk_core;
  initial #500 pll_lock=1;
endmodule
module tb_continuous;
  reg clk=0;
  always #18.5185185 clk=~clk;
  wire uart;
  top #(.BASE_CYCLES(64),.STARTUP_CYCLES(64),.SAMPLES(4),.UART_DIV(8)) dut(clk,uart);
  reg [7:0] bytes[0:20];
  reg [7:0] sum;
  reg [31:0] cycles,got,expected,early,late;
  integer packet,byte_index,bit_index,frequency,steps;
  function [31:0] advance;
    input integer n;
    reg [31:0] state;
    integer i;
    begin
      state=1;
      for(i=0;i<n;i=i+1) state={state[30:0],state[31]^state[21]^state[1]^state[0]};
      advance=state;
    end
  endfunction
  initial begin
    for(packet=0;packet<4;packet=packet+1) begin
      for(byte_index=0;byte_index<21;byte_index=byte_index+1) begin
        @(negedge uart);
        #(8*37.037037*1.5);
        for(bit_index=0;bit_index<8;bit_index=bit_index+1) begin
          bytes[byte_index][bit_index]=uart;
          #(8*37.037037);
        end
        if(uart !== 1'b1) $fatal(1,"bad UART stop bit");
      end
      sum=0;
      for(byte_index=0;byte_index<21;byte_index=byte_index+1) sum=sum^bytes[byte_index];
      if(sum!=0 || {bytes[3],bytes[2],bytes[1],bytes[0]} != 32'h31435046 && {bytes[3],bytes[2],bytes[1],bytes[0]} != 32'h32435046) $fatal(1,"bad frame");
      if({bytes[7],bytes[6]} != packet) $fatal(1,"bad sample index");
      frequency={bytes[5],bytes[4]};
      cycles={bytes[11],bytes[10],bytes[9],bytes[8]};
      got={bytes[15],bytes[14],bytes[13],bytes[12]};
      if(cycles != 256) $fatal(1,"bad run window");
      expected=got;
      for(steps=0;steps<256;steps=steps+1)
        expected={expected[30:0],expected[31]^expected[21]^expected[1]^expected[0]};
      got={bytes[19],bytes[18],bytes[17],bytes[16]};
      if(got !== expected || expected==0) $fatal(1,"continuous pair mismatch");
      $display("frame %0d frequency=%0d cycles=%0d state=%h",packet,frequency,cycles,got);
    end
    $display("PASS continuous UART and 256-cycle snapshot pairs");
    $finish;
  end
  initial begin #10000000; $fatal(1,"timeout"); end
endmodule
