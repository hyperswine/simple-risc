`timescale 1ns/1ps
module reset_equivalence_tb;
 reg clk=0; always #5 clk=~clk;
 reg reset=1,held=0; reg [31:0] data=0,read0=0;
 wire [21:0] ba,ca; wire bw,cw;wire [31:0] bd,cd;wire [3:0] bm,cm;
 wire bt,ct,bs,cs,bo,co,bc,cc;
 wire br,cr,bi,ci,be,ce,bredirect,credirect;
 wire [31:0] bword,cword,bpc,cpc,bnext,cnext,bfetch,cfetch;
 baseline_core baseline(.clk(clk),.reset(reset),.enable(1'b1),.uart_rx(1'b1),
 .memory_data(data),.memory_hold(held),.sd_miso(1'b1),.uart_tx(bt),
 .memory_address(ba),.memory_write(bw),.memory_wdata(bd),.memory_mask(bm),
 .sd_sck(bs),.sd_mosi(bo),.sd_cs(bc),.observe_commit(br),.observe_word(bword),
 .observe_pc(bpc),.observe_next_pc(bnext),.observe_issue(bi),.observe_fetch_pc(bfetch),
 .observe_empty(be),.observe_redirect(bredirect));
 candidate_core candidate(.clk(clk),.reset(reset && !($test$plusargs("IGNORE_CANDIDATE_RESET") && epoch>0)),.enable(1'b1),.uart_rx(1'b1),
 .memory_data(data),.memory_hold(held),.sd_miso(1'b1),.uart_tx(ct),
 .memory_address(ca),.memory_write(cw),.memory_wdata(cd),.memory_mask(cm),
 .sd_sck(cs),.sd_mosi(co),.sd_cs(cc),.observe_commit(cr),.observe_word(cword),
 .observe_pc(cpc),.observe_next_pc(cnext),.observe_issue(ci),.observe_fetch_pc(cfetch),
 .observe_empty(ce),.observe_redirect(credirect));
 // Two cache-side logical read stages; the core owns the request register.
 // A small repeated arithmetic/load/store/branch program, without peripherals.
 function [31:0] word_at(input [21:0] address);
 begin
  if(address[21]) word_at=address[8:0]==0 ? 32'h800000b7:32'h00008067;
  else case(address[5:0])
   0:word_at=32'h00700113; // addi x2,x0,7
   1:word_at=32'h002101b3; // add x3,x2,x2
   2:word_at=32'h02218233; // mul x4,x3,x2
   3:word_at=32'h022242b3; // div x5,x4,x2
   4:word_at=32'h1040a023; // sw x4,256(x1)
   5:word_at=32'h1000a303; // lw x6,256(x1)
   6:word_at=32'h00130313; // addi x6,x6,1
   7:word_at=32'hb0011073; // csrrw x0,mcycle,x2
   8:word_at=32'hb8019073; // csrrw x0,mcycleh,x3
   9:word_at=32'hc00023f3; // csrrs x7,cycle,x0
   10:word_at=32'hc8002473; // csrrs x8,cycleh,x0
   11:word_at=32'h1070a223; // sw x7,260(x1)
   12:word_at=32'h1080a423; // sw x8,264(x1)
   13:word_at=32'hfcdff06f; // jal x0,-52
   default:word_at=32'h00000013;
  endcase
 end endfunction
 always @(posedge clk)begin
  if(reset)begin data<=0;read0<=0;end
  else if(!held)begin read0<=word_at(ba);data<=read0;end
 end
 integer cycles=0,commits=0,stores=0,resets=0,held_resets=0,epoch_commits=0;
 integer epoch=0,seed=32'h1a2b3c4d,remaining=5,phase=0;
 always @(negedge clk)begin
  cycles=cycles+1;
  // Compare externally visible effects and valid observation fields only.
  if(!reset)begin
   if({bt,bs,bo,bc,bw,br,bi,bredirect} !== {ct,cs,co,cc,cw,cr,ci,credirect})
    $fatal(1,"control mismatch cycle=%0d epoch=%0d",cycles,epoch);
   if(bw && !held && {ba,bd,bm} !== {ca,cd,cm})$fatal(1,"store mismatch epoch=%0d",epoch);
   if(bi && !held && {ba,bfetch} !== {ca,cfetch})$fatal(1,"fetch mismatch epoch=%0d",epoch);
   if(br && !held)begin
    if({bword,bpc,bnext} !== {cword,cpc,cnext})$fatal(1,"retirement mismatch epoch=%0d",epoch);
    commits=commits+1;epoch_commits=epoch_commits+1;
   end
   if(bw && !held)stores=stores+1;
  end
  seed={seed[30:0],seed[31]^seed[21]^seed[1]^seed[0]};
  if(remaining>0)begin
   remaining=remaining-1;
   held=epoch[0];
   if(remaining==0)begin reset=0;phase=0;epoch_commits=0;end
  end else begin
   phase=phase+1;held=(seed[3:0]<5);
   // Vary reset position to interrupt instructions, division and held stages.
   if(phase==400+epoch*17)begin
    if(epoch_commits<8)$fatal(1,"insufficient execution before reset: %0d",epoch_commits);
    if(epoch==20)begin
     if(commits<160 || stores==0 || held_resets==0)$fatal(1,"coverage missing");
     $display("PASS: reset equivalence, %0d warm resets, %0d while held, %0d commits, %0d stores",resets,held_resets,commits,stores);
     $finish;
    end else begin
     resets=resets+1;if(held)held_resets=held_resets+1;
     epoch=epoch+1;reset=1;remaining=3+epoch%5;
    end
   end
  end
  if(cycles>20000)$fatal(1,"timeout");
 end
endmodule
