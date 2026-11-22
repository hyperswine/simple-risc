`timescale 1ns/1ps
// servo_pwm: accepted widths appear as that many microseconds high in each
// 20 ms frame, from the next frame boundary; invalid widths are ignored and
// zero disables. Run with
//   iverilog -g2012 -o /tmp/servo_tb servo_pwm.v servo_pwm_tb.v && vvp /tmp/servo_tb
module servo_pwm_tb;
 localparam CPU = 4; // clocks per microsecond, small to keep the run short
 localparam FRAME = 20000*CPU;
 reg clk=0; always #5 clk=~clk;
 reg reset=1, write=0; reg [31:0] width=0;
 wire signal;
 servo_pwm #(.CLOCKS_PER_US(CPU)) dut(.clk(clk),.reset(reset),.write_pulse(write),.pulse_us(width),.signal(signal));
 integer failures=0, high=0, frames=0, edges=0;
 reg last=0;
 task command(input [31:0] us);
 begin @(negedge clk); write=1; width=us; @(negedge clk); write=0; width=32'hdead_beef; end
 endtask
 // High clocks in one frame, counted from the first rising edge seen.
 task measure(output integer clocks);
 integer n;
 begin
  clocks=0;
  for(n=0;n<FRAME;n=n+1) begin @(posedge clk); #1 if(signal) clocks=clocks+1; end
 end
 endtask
 task expect_frames(input integer us, input [8*24-1:0] what);
 integer c, k;
 begin
  for(k=0;k<2;k=k+1) begin
   measure(c);
   if(c!=us*CPU) begin failures=failures+1; $display("FAIL %0s: %0d clocks high, expected %0d", what, c, us*CPU); end
  end
 end
 endtask
 // Wait until just after a frame boundary (the start of a high period, or
 // the boundary counter wrap when disabled).
 task to_boundary;
 begin
  @(posedge clk); while(!(dut.frame_us==0 && dut.divider==0)) @(posedge clk);
 end
 endtask
 initial begin
  repeat(4) @(posedge clk); @(negedge clk); reset=0;
  if(signal) begin failures=failures+1; $display("FAIL: high out of reset"); end
  command(1500); to_boundary; repeat(2) @(posedge clk); expect_frames(1500,"1500 us");
  command(1400); to_boundary; repeat(2) @(posedge clk); expect_frames(1400,"1400 us");
  command(999);  to_boundary; repeat(2) @(posedge clk); expect_frames(1400,"999 ignored");
  command(2001); to_boundary; repeat(2) @(posedge clk); expect_frames(1400,"2001 ignored");
  command(32'h0001_05dc); to_boundary; repeat(2) @(posedge clk); expect_frames(1400,"high bits ignored");
  command(2000); to_boundary; repeat(2) @(posedge clk); expect_frames(2000,"2000 us");
  command(1000); to_boundary; repeat(2) @(posedge clk); expect_frames(1000,"1000 us");
  command(0);    to_boundary; repeat(2) @(posedge clk); expect_frames(0,"disabled");
  // A command mid-frame does not cut the current pulse short.
  command(1600); to_boundary; repeat(2) @(posedge clk);
  repeat(100*CPU) @(posedge clk); command(1200);
  begin : partial integer c,n; c=100*CPU;
   for(n=100*CPU+2;n<FRAME;n=n+1) begin @(posedge clk); #1 if(signal) c=c+1; end
   if(c<1599*CPU || c>1601*CPU) begin failures=failures+1; $display("FAIL mid-frame: %0d clocks", c); end
  end
  to_boundary; repeat(2) @(posedge clk); expect_frames(1200,"1200 after mid-frame");
  // Level mode: 1 drives the pin high at once and holds it; 0 drops it at
  // once. PWM stops at the next boundary underneath the level.
  repeat(300*CPU) @(posedge clk); command(1); #1
  if(!signal) begin failures=failures+1; $display("FAIL: level 1 not immediate"); end
  expect_frames(20000,"level high");
  command(32'h0001_0001); expect_frames(20000,"level ignores high bits");
  repeat(77) @(posedge clk); command(0); #1
  if(signal) begin failures=failures+1; $display("FAIL: level 0 not immediate"); end
  expect_frames(0,"level low");
  // From level to PWM: the level drops at once, the pulse starts at the boundary.
  command(1); repeat(10) @(posedge clk); command(1700); #1
  if(signal && !(dut.frame_us < dut.active_us)) begin failures=failures+1; $display("FAIL: level held after PWM write"); end
  to_boundary; repeat(2) @(posedge clk); expect_frames(1700,"1700 after level");
  // From PWM to level 0 mid-pulse: the pulse in progress finishes.
  to_boundary; repeat(500*CPU) @(posedge clk); command(0);
  begin : runt integer c,n; c=500*CPU;
   for(n=500*CPU+2;n<FRAME;n=n+1) begin @(posedge clk); #1 if(signal) c=c+1; end
   if(c<1699*CPU || c>1701*CPU) begin failures=failures+1; $display("FAIL: pulse cut by 0: %0d clocks", c); end
  end
  to_boundary; repeat(2) @(posedge clk); expect_frames(0,"disabled after PWM");
  // Reset drops the output at once and disables it.
  repeat(10) @(posedge clk); @(negedge clk); reset=1; repeat(3) @(posedge clk); #1
  if(signal) begin failures=failures+1; $display("FAIL: high during reset"); end
  @(negedge clk); reset=0; to_boundary; repeat(2) @(posedge clk); expect_frames(0,"disabled after reset");
  if(failures==0) $display("PASS servo_pwm"); else $display("FAILED servo_pwm: %0d", failures);
  $finish;
 end
endmodule
