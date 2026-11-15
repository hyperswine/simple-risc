`timescale 1ns/1ps
// Behavioral clock stub: tests feeder/reset logic, not PLL electrical behavior.
module deflate_pll #(parameter FBDIV_SEL=0, IDIV_SEL=0, ODIV_SEL=0)
  (input clk_27m, output clk_core, clk_sdram, pll_lock);
  assign clk_core=clk_27m;
  assign clk_sdram=clk_27m;
  assign pll_lock=1'b1;
endmodule
module tb_deflate_fpga;
  reg clk=0, btn=0;
  always #5 clk=~clk;
  wire obs;
  top dut(.clk_27m(clk),.btn_s1(btn),.uart_tx(obs));
  reg [7:0] expected[0:16383];
  reg [2047:0] expected_file;
  integer count=0, cycles=0, run=0;
  initial begin
    if (!$value$plusargs("EXPECTED=%s",expected_file)) $fatal(1,"missing expected");
    $readmemh(expected_file,expected);
    repeat(5) @(negedge clk);
    btn=1;
    // Abort one stream after output starts, then verify two complete replays.
    wait(count==100);
    @(negedge clk); btn=0;
    repeat(5) @(negedge clk);
    run=1; btn=1;
    wait(count==16384);
    repeat(10) @(negedge clk);
    if (!dut.done || dut.bad) $fatal(1,"first replay failed to terminate");
    btn=0;
    repeat(5) @(negedge clk);
    run=2; btn=1;
    wait(count==16384);
    repeat(10) @(negedge clk);
    if (!dut.done || dut.bad) $fatal(1,"second replay failed to terminate");
    $display("PASS wrapper: midstream reset and two complete 16384-byte replays");
    $finish;
  end
  always @(posedge clk) begin
    cycles=cycles+1;
    if (dut.reset) count=0;
    else begin
      if (dut.bad) $fatal(1,"decoder rejected wrapper stream");
      if (dut.out_valid) begin
        if(count>=16384 || dut.out_byte !== expected[count])
          $fatal(1,"wrapper run=%0d byte=%0d got=%02x expected=%02x",run,count,dut.out_byte,expected[count]);
        count=count+1;
      end
    end
    if(cycles>300000) $fatal(1,"wrapper timeout");
  end
endmodule
