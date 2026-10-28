// CPU-level FENCE.I epoch monitor for the generated pipelined SimpleRisc RTL.
// A hold freezes commit and fetch together, so only advancing edges are sampled.
module pipeline_fence_assertions(
 input clk,input reset,input hold,
 input commit_valid,input [31:0] commit_instruction,
 input [31:0] commit_pc,input [31:0] commit_next_pc,
 input fetch_issue,input [31:0] fetch_pc,input pipeline_empty);
 localparam [31:0] FENCE_I=32'h0000100f;
 reg awaiting_memory_fetch=0,awaiting_commit=0;
 reg [31:0] expected_pc=0;
 integer commits=0,memory_fetches=0,verified_fences=0;
 always @(posedge clk)begin
   if(reset)begin
     awaiting_memory_fetch<=0;awaiting_commit<=0;
     commits=0;memory_fetches=0;verified_fences=0;
   end else if(!hold)begin
     if(awaiting_memory_fetch && !pipeline_empty)
       $fatal(1,"ASSERT: FENCE.I pre-fence pipeline state survived flush");
     // No older pipeline entry may commit after the fence. The first newer
     // commit must follow the new fetch and name the fence's sequential PC.
     if(awaiting_commit && commit_valid)begin
       if(awaiting_memory_fetch)
         $fatal(1,"ASSERT: FENCE.I consumed pre-fence buffered instruction before memory refetch");
       if(commit_pc!==expected_pc)
         $fatal(1,"ASSERT: FENCE.I post-fence commit PC %h expected %h",commit_pc,expected_pc);
       awaiting_commit<=0;verified_fences=verified_fences+1;
     end
     if(awaiting_memory_fetch && fetch_issue)begin
       if(fetch_pc!==expected_pc)
         $fatal(1,"ASSERT: FENCE.I refetch PC %h expected %h",fetch_pc,expected_pc);
       awaiting_memory_fetch<=0;memory_fetches=memory_fetches+1;
     end
     // This also handles consecutive fences: the checks above close the old
     // epoch on its first commit, then these assignments open the new epoch.
     if(commit_valid && commit_instruction==FENCE_I)begin
       expected_pc<=commit_next_pc;awaiting_memory_fetch<=1;awaiting_commit<=1;
       commits=commits+1;
     end
   end
 end
endmodule
