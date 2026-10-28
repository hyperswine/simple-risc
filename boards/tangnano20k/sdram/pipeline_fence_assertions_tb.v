`timescale 1ns/1ps
module pipeline_fence_assertions_tb #(parameter STALE_SOURCE=0);
 reg clk=0;always #5 clk=~clk;
 reg reset=1,hold=0,commit_valid=0,fetch_issue=0,pipeline_empty=1;
 reg [31:0] instruction=0,commit_pc=0,commit_next_pc=0,fetch_pc=0;
 pipeline_fence_assertions monitor(clk,reset,hold,commit_valid,instruction,
   commit_pc,commit_next_pc,fetch_issue,fetch_pc,pipeline_empty);
 initial begin
   repeat(2)@(negedge clk);reset=0;
   @(negedge clk);commit_valid=1;instruction=32'h0000100f;
   commit_pc=32'h100;commit_next_pc=32'h104;
   if(STALE_SOURCE==2)begin
     // A matching-PC fetch cannot excuse retained pre-fence pipeline state.
     @(negedge clk);pipeline_empty=0;commit_pc=32'h104;instruction=0;
     commit_next_pc=32'h108;fetch_issue=1;fetch_pc=32'h104;
     @(negedge clk);commit_valid=0;fetch_issue=0;
   end else if(STALE_SOURCE)begin
     // A pre-fence pipeline entry commits without any new memory fetch.
     @(negedge clk);commit_pc=32'h100;instruction=0;commit_next_pc=32'h104;
     @(negedge clk);commit_valid=0;
   end else begin
     @(negedge clk);commit_valid=0;fetch_issue=1;fetch_pc=32'h104;
     @(negedge clk);fetch_issue=0;commit_valid=1;instruction=0;
     commit_pc=32'h104;commit_next_pc=32'h108;
     @(negedge clk);commit_valid=0;
   end
   @(posedge clk);#1;
   if(monitor.commits!=1 || monitor.memory_fetches!=1 || monitor.verified_fences!=1 ||
     monitor.awaiting_memory_fetch || monitor.awaiting_commit)
     $fatal(1,"FENCE.I monitor coverage/state mismatch");
   $display("PASS: FENCE.I commit requires a memory fetch");$finish;
 end
 initial begin repeat(20)@(posedge clk);$fatal(1,"FENCE.I monitor unit timeout");end
endmodule
