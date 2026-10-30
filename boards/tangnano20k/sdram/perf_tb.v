`timescale 1ns/1ps
// Where the SDRAM pipeline's cycles go, in simulation.
//
// The generated CPU, the real cache, the optional clock bridge, the real
// burst controller and a functional SDRAM pin model run a preloaded image.
// A two-instruction ROM jumps to 0x8000_0000, so there is no UART upload.
// UART output is decoded and echoed; the run ends at END_MARKER or the cycle
// limit. Counters come from the cache's own state and are printed at the end.
// This measures cycles, not electrical timing; it is not an I/O signoff.
module perf_tb #(
 parameter ROM_FILE="rom.hex",
 parameter CDC_BRIDGE=1,
 parameter real CPU_MHZ=72.0,
 parameter real MEM_MHZ=54.0,
 parameter PHASE_DEGREES=135,
 parameter UART_BIT=32,
 parameter LINE_BITS=11,
 parameter WRITE_UPDATE=1,
 parameter WAYS=2,
 parameter PROFILE_CPU=0
);
 localparam real CPU_NS=1000.0/CPU_MHZ;
 localparam real MEM_NS=1000.0/MEM_MHZ;
 reg clk=0;always #(CPU_NS/2.0) clk=~clk;
 reg memory_clk=0;
 initial begin #(CPU_NS*0.313);forever #(MEM_NS/2.0) memory_clk=~memory_clk;end
 wire backend_clk=CDC_BRIDGE ? memory_clk:clk;
 reg reset=1;
 reg [1:0] cpu_reset_pipe=3,mem_reset_pipe=3;
 always @(posedge clk or posedge reset)if(reset)cpu_reset_pipe<=3;else cpu_reset_pipe<={cpu_reset_pipe[0],1'b0};
 always @(posedge backend_clk or posedge reset)if(reset)mem_reset_pipe<=3;else mem_reset_pipe<={mem_reset_pipe[0],1'b0};
 wire core_reset=cpu_reset_pipe[1];
 wire backend_reset=CDC_BRIDGE ? mem_reset_pipe[1]:core_reset;

 wire uart_tx,hold_cpu,cpu_write,sd_sck,sd_mosi,sd_cs;
 wire [21:0] cpu_address;wire [31:0] cpu_wdata,cpu_rdata;wire [3:0] cpu_mask;
 sdram_pipeline_risc cpu(.clk(clk),.reset(core_reset),.enable(1'b1),
   .uart_rx(1'b1),.uart_tx(uart_tx),.memory_data(cpu_rdata),.memory_hold(hold_cpu),
   .memory_address(cpu_address),.memory_write(cpu_write),.memory_wdata(cpu_wdata),.memory_mask(cpu_mask),
   .sd_miso(1'b1),.sd_sck(sd_sck),.sd_mosi(sd_mosi),.sd_cs(sd_cs));
 wire c_req,c_write,c_ready,c_done,c_valid;
 wire [20:0] c_address;wire [31:0] c_wdata,c_rdata;wire [3:0] c_mask;wire [1:0] c_word_index;
 sdram_pipeline_cache #(.LINE_BITS(LINE_BITS),.WRITE_UPDATE(WRITE_UPDATE),.WAYS(WAYS),.ROM_FILE(ROM_FILE)) cache(clk,core_reset,
   cpu_address,cpu_write,cpu_wdata,cpu_mask,hold_cpu,cpu_rdata,
   c_req,c_write,c_address,c_wdata,c_mask,c_ready,c_done,c_rdata,c_valid,c_word_index);
 wire req,write,ready,done,valid;wire [20:0] address;wire [31:0] wdata,rdata;
 wire [3:0] mask;wire [1:0] word_index;
 generate if(CDC_BRIDGE)begin: clock_crossing
   sdram_clock_bridge bridge(.cpu_clk(clk),.cpu_reset(core_reset),
     .cpu_req(c_req),.cpu_write(c_write),.cpu_address(c_address),.cpu_wdata(c_wdata),.cpu_mask(c_mask),
     .cpu_ready(c_ready),.cpu_done(c_done),.cpu_rdata(c_rdata),.cpu_word_valid(c_valid),.cpu_word_index(c_word_index),
     .mem_clk(backend_clk),.mem_reset(backend_reset),
     .mem_req(req),.mem_write(write),.mem_address(address),.mem_wdata(wdata),.mem_mask(mask),
     .mem_ready(ready),.mem_done(done),.mem_rdata(rdata),.mem_word_valid(valid),.mem_word_index(word_index));
 end else begin: common_clock
   assign req=c_req;assign write=c_write;assign address=c_address;assign wdata=c_wdata;assign mask=c_mask;
   assign c_ready=ready;assign c_done=done;assign c_rdata=rdata;assign c_valid=valid;assign c_word_index=word_index;
 end endgenerate

 // Functional SDRAM pins, as in pipeline_cpu_tb.v (CAS2, burst 4).
 reg [31:0] ram[0:2097151];
 wire sclk,cke,cs_n,cas_n,ras_n,we_n;
 wire [3:0] dqm;wire [10:0] sa;wire [1:0] ba;tri [31:0] dq;
 reg phase_clk=0;
 always @(backend_clk)phase_clk<=#((CDC_BRIDGE ? MEM_NS:CPU_NS)*PHASE_DEGREES/360.0)backend_clk;
 sdram_burst_memory #(.FREQ(CDC_BRIDGE ? MEM_MHZ*1000000:CPU_MHZ*1000000)) mem(backend_clk,phase_clk,backend_reset,
   req,write,address,wdata,mask,ready,done,rdata,valid,word_index,sclk,cke,cs_n,cas_n,ras_n,we_n,dqm,sa,ba,dq);
 reg [10:0] open_row[0:3];reg [3:0] bank_open=0;reg [10:0] mode=0;reg configured=0;
 reg drive=0;reg [31:0] pin_data=0;
 assign dq=drive ? pin_data:32'bz;
 integer read_delay=0,read_beat=0,pin_lane,physical_word;
 reg active_read=0;reg [20:0] read_base;reg [1:0] read_bank;
 always @(posedge sclk)begin
   if(backend_reset)begin active_read=0;read_delay=0;read_beat=0;drive=0;bank_open=0;configured=0;mode=0;end
   else begin
     if(active_read)begin
       if(read_delay>1)begin read_delay=read_delay-1;drive=0;end
       else begin
         if(read_delay==1)read_delay=0;
         drive=1;pin_data=ram[read_base+read_beat];
         if(read_beat==3)begin active_read=0;bank_open[read_bank]=0;end
         else read_beat=read_beat+1;
       end
     end else drive=0;
     case({ras_n,cas_n,we_n})
       3'b111:begin end
       3'b010:if(sa[10])bank_open=0;else bank_open[ba]=0;
       3'b001:begin end
       3'b000:begin mode=sa;configured=1;end
       3'b011:begin open_row[ba]=sa;bank_open[ba]=1;end
       3'b101:begin read_base={ba,open_row[ba],sa[7:0]};read_bank=ba;read_delay=mode[6:4]-1;read_beat=0;active_read=1;end
       3'b100:begin
         physical_word={ba,open_row[ba],sa[7:0]};
         for(pin_lane=0;pin_lane<4;pin_lane=pin_lane+1)if(!dqm[pin_lane])
           ram[physical_word][pin_lane*8+:8]=dq[pin_lane*8+:8];
         bank_open[ba]=0;
       end
       default:$fatal(1,"unsupported SDRAM pin command");
     endcase
   end
 end

 // Counters, all in CPU clocks.
 localparam IDLE=0,WRITE_SEND=1,WRITE_WAIT=2,READ_SEND=3,READ_WAIT=4;
 integer text_end_word=0;
 reg [63:0] cycles=0,held=0,held_read=0,held_write_full=0,held_clear=0;
 reg [63:0] miss_draining=0,miss_filling=0,fills=0,code_fills=0,writes_sent=0,stores=0;
 reg [63:0] store_invalidated_fills=0,store_hit_invalidations=0,store_updates=0;
 reg [63:0] window_start=0,window_cycles=0,window_held=0,window_fills=0,window_writes=0;
 reg [19-LINE_BITS:0] killed_tag[0:(1<<LINE_BITS)-1];
 reg killed[0:(1<<LINE_BITS)-1];
 integer k;
 initial for(k=0;k<(1<<LINE_BITS);k=k+1)begin killed[k]=0;killed_tag[k]=0;end
 wire [LINE_BITS-1:0] line2=cache.a2[LINE_BITS+1:2];
 wire [18-LINE_BITS:0] tag2=cache.a2[20:LINE_BITS+2];
 reg measuring=0;
 always @(posedge clk)if(!core_reset)begin
   cycles<=cycles+1;
   if(hold_cpu)held<=held+1;
   if(cache.read_miss)held_read<=held_read+1;
   else if(cache.write_full)held_write_full<=held_write_full+1;
   if(cache.clearing)held_clear<=held_clear+1;
   if(cache.read_miss && (cache.state==WRITE_SEND || cache.state==WRITE_WAIT ||
      (cache.state==IDLE && cache.write_count!=0)))miss_draining<=miss_draining+1;
   if(cache.read_miss && (cache.state==READ_SEND || cache.state==READ_WAIT))miss_filling<=miss_filling+1;
   if(cache.state==READ_SEND && c_ready)begin
     fills<=fills+1;
     if(cache.a2[20:0]<text_end_word)code_fills<=code_fills+1;
     if(killed[line2] && killed_tag[line2]==tag2)store_invalidated_fills<=store_invalidated_fills+1;
     killed[line2]<=0;
   end
   if(cache.state==WRITE_SEND && c_ready)writes_sent<=writes_sent+1;
   if(cache.push)begin
     stores<=stores+1;
     if(cache.update)store_updates<=store_updates+1;
     // The store's lookup hit but it drops the line anyway.
     else if(cache.hit2)begin
       store_hit_invalidations<=store_hit_invalidations+1;
       killed[line2]<=1;killed_tag[line2]<=tag2;
     end
   end
   if(measuring)begin
     window_cycles<=window_cycles+1;
     if(hold_cpu)window_held<=window_held+1;
     if(cache.state==READ_SEND && c_ready)window_fills<=window_fills+1;
     if(cache.state==WRITE_SEND && c_ready)window_writes<=window_writes+1;
   end
 end

 // Optional observation of the current generated CPU ABI. The runner checks
 // these exact field declarations before enabling this instrumentation.
 reg [63:0] window_pipeline_commits=0,window_redirects=0;
 generate if(PROFILE_CPU)begin: cpu_profile
   always @(posedge clk)if(!core_reset && !hold_cpu && measuring)begin
`ifdef LEGACY_PROFILE_20261028
     // Explicit opt-in for exact replay of archived pre-observation netlists.
     if(cpu.mCommits)window_pipeline_commits<=window_pipeline_commits+1;
     if(cpu.e2Moved[659] && cpu.e2Moved[100])window_redirects<=window_redirects+1;
`elsif NAMED_PIPELINE_OBSERVATIONS
     if(cpu.observe_commit)window_pipeline_commits<=window_pipeline_commits+1;
     if(cpu.observe_redirect)window_redirects<=window_redirects+1;
`endif
   end
 end endgenerate

 // Issue-slot accounting (named-v2 ABI): every unheld measured cycle gets one
 // cause from the CPU's own step function, so slot_* plus window_held equals
 // window_cycles. A front-end bubble is a refill while no instruction has
 // issued since the last restart (redirect, handover or FENCE.I).
 reg [63:0] slot_issue=0,slot_slow=0,slot_restart=0,slot_load_wait=0,slot_mul_wait=0,slot_other_wait=0;
 reg [63:0] slot_port_conflict=0,slot_hazard=0,slot_frontend_refill=0,slot_frontend_other=0,slot_other=0;
 reg [63:0] fetch_port_blocked=0;
`ifdef NAMED_SLOT_OBSERVATIONS
 reg refilling=0;
 always @(posedge clk)if(!core_reset && !hold_cpu)begin
   if(cpu.observe_slot==2)refilling<=1;
   else if(cpu.observe_slot==0)refilling<=0;
   if(measuring)begin
     case(cpu.observe_slot)
       0:slot_issue<=slot_issue+1;
       1:slot_slow<=slot_slow+1;
       2:slot_restart<=slot_restart+1;
       3:slot_load_wait<=slot_load_wait+1;
       4:slot_mul_wait<=slot_mul_wait+1;
       5:slot_other_wait<=slot_other_wait+1;
       6:slot_port_conflict<=slot_port_conflict+1;
       7:slot_hazard<=slot_hazard+1;
       8:if(refilling)slot_frontend_refill<=slot_frontend_refill+1;else slot_frontend_other<=slot_frontend_other+1;
       default:slot_other<=slot_other+1;
     endcase
     if(cpu.observe_fetch_port_blocked)fetch_port_blocked<=fetch_port_blocked+1;
   end
 end
`endif

 // Finer splits (named-v3): the producer behind each hazard cycle, the kind
 // of each redirect, committed control instructions by kind, and how long
 // each restart takes to issue its first instruction.
 reg [63:0] hazard_cause[0:15];
 reg [63:0] redirect_kind[0:7];
 reg [63:0] ctl_load=0,ctl_store=0,ctl_shift=0,ctl_mul=0;
 reg [63:0] ctl_branch=0,ctl_branch_taken=0,ctl_jal=0,ctl_jal_link=0,ctl_return=0,ctl_jalr=0,ctl_jalr_link=0;
 reg [63:0] restart_length[0:16];
 reg [63:0] refill_port_blocked=0;
 integer restart_run=0;
 initial begin
   for(k=0;k<16;k=k+1)hazard_cause[k]=0;
   for(k=0;k<8;k=k+1)redirect_kind[k]=0;
   for(k=0;k<17;k=k+1)restart_length[k]=0;
 end
`ifdef NAMED_SPLIT_OBSERVATIONS
 wire [6:0] commit_opcode=cpu.observe_word[6:0];
 wire [4:0] commit_rd=cpu.observe_word[11:7];
 wire [4:0] commit_rs1=cpu.observe_word[19:15];
 integer control_trace=0;
 reg redirect_pending=0;
 reg [4095:0] control_trace_file;
 initial if($value$plusargs("CONTROL_TRACE=%s",control_trace_file))control_trace=$fopen(control_trace_file,"w");
 always @(posedge clk)if(!core_reset && !hold_cpu)begin
   // restart_run counts the restart cycle and every cycle until an issue.
   if(cpu.observe_slot==2)restart_run<=1;
   else if(restart_run!=0)begin
     if(cpu.observe_slot==0)begin
       if(measuring)restart_length[restart_run>16?16:restart_run]<=restart_length[restart_run>16?16:restart_run]+1;
       restart_run<=0;
     end else restart_run<=restart_run+1;
   end
   if(measuring)begin
     if(cpu.observe_slot==7)hazard_cause[cpu.observe_hazard]<=hazard_cause[cpu.observe_hazard]+1;
     if(cpu.observe_redirect)redirect_kind[cpu.observe_redirect_kind]<=redirect_kind[cpu.observe_redirect_kind]+1;
     if(cpu.observe_slot==8 && refilling && cpu.observe_fetch_port_blocked)refill_port_blocked<=refill_port_blocked+1;
     if(cpu.observe_commit)begin
       case(commit_opcode)
         7'h63:begin
           ctl_branch<=ctl_branch+1;
           if(cpu.observe_next_pc!=cpu.observe_pc+2 && cpu.observe_next_pc!=cpu.observe_pc+4)ctl_branch_taken<=ctl_branch_taken+1;
         end
         7'h6f:begin ctl_jal<=ctl_jal+1;if(commit_rd!=0)ctl_jal_link<=ctl_jal_link+1;end
         7'h67:begin
           if(commit_rd==0 && (commit_rs1==1 || commit_rs1==5))ctl_return<=ctl_return+1;
           else begin ctl_jalr<=ctl_jalr+1;if(commit_rd!=0)ctl_jalr_link<=ctl_jalr_link+1;end
         end
         7'h03:ctl_load<=ctl_load+1;
         7'h23:ctl_store<=ctl_store+1;
         7'h13:if(cpu.observe_word[13:12]==2'b01)ctl_shift<=ctl_shift+1;
         7'h33:if(cpu.observe_word[25])ctl_mul<=ctl_mul+1;
               else if(cpu.observe_word[13:12]==2'b01)ctl_shift<=ctl_shift+1;
         default:;
       endcase
       // The fourth field is 1 when this instruction redirected fetch: E2
       // redirects as it moves into M, so the next commit is that instruction.
       if(control_trace!=0 && (commit_opcode==7'h63 || commit_opcode==7'h6f || commit_opcode==7'h67))
         $fwrite(control_trace,"%h %h %h %0d\n",cpu.observe_pc,cpu.observe_word,cpu.observe_next_pc,redirect_pending);
       redirect_pending<=0;
     end
     if(cpu.observe_redirect)redirect_pending<=1;
   end
 end
`endif

 // UART receiver for the CPU's transmitter (UART_BIT clocks per bit).
 reg [8*64-1:0] line_text=0;integer line_length=0;
 reg [8*64-1:0] end_marker,start_marker;
 integer bit_index;reg [7:0] received;
 task finish_run;
 begin
   $display("PERF cycles=%0d held=%0d held_read_miss=%0d held_write_full=%0d held_clear=%0d",
     cycles,held,held_read,held_write_full,held_clear);
   $display("PERF miss_draining=%0d miss_filling=%0d fills=%0d code_fills=%0d writes=%0d stores=%0d",
     miss_draining,miss_filling,fills,code_fills,writes_sent,stores);
   $display("PERF store_updates=%0d store_hit_invalidations=%0d store_invalidated_fills=%0d",
     store_updates,store_hit_invalidations,store_invalidated_fills);
   $display("PERF window_cycles=%0d window_held=%0d window_fills=%0d window_writes=%0d",
     window_cycles,window_held,window_fills,window_writes);
   $display("PERF window_pipeline_commits=%0d window_redirects=%0d",window_pipeline_commits,window_redirects);
`ifdef NAMED_SLOT_OBSERVATIONS
   $display("PERF slot_issue=%0d slot_slow=%0d slot_restart=%0d slot_load_wait=%0d slot_mul_wait=%0d slot_other_wait=%0d",
     slot_issue,slot_slow,slot_restart,slot_load_wait,slot_mul_wait,slot_other_wait);
   $display("PERF slot_port_conflict=%0d slot_hazard=%0d slot_frontend_refill=%0d slot_frontend_other=%0d slot_other=%0d fetch_port_blocked=%0d",
     slot_port_conflict,slot_hazard,slot_frontend_refill,slot_frontend_other,slot_other,fetch_port_blocked);
`endif
`ifdef NAMED_SPLIT_OBSERVATIONS
   $write("PERF");for(k=0;k<16;k=k+1)$write(" hazard_%0d=%0d",k,hazard_cause[k]);$write("\n");
   $write("PERF");for(k=0;k<8;k=k+1)$write(" redirect_kind_%0d=%0d",k,redirect_kind[k]);$write("\n");
   $write("PERF");for(k=0;k<17;k=k+1)$write(" restart_length_%0d=%0d",k,restart_length[k]);$write("\n");
   $display("PERF ctl_load=%0d ctl_store=%0d ctl_shift=%0d ctl_mul=%0d",ctl_load,ctl_store,ctl_shift,ctl_mul);
   $display("PERF ctl_branch=%0d ctl_branch_taken=%0d ctl_jal=%0d ctl_jal_link=%0d ctl_return=%0d ctl_jalr=%0d ctl_jalr_link=%0d refill_port_blocked=%0d",
     ctl_branch,ctl_branch_taken,ctl_jal,ctl_jal_link,ctl_return,ctl_jalr,ctl_jalr_link,refill_port_blocked);
   if(control_trace!=0)$fclose(control_trace);
`endif
   $finish;
 end endtask
 initial begin
   if(!$value$plusargs("END=%s",end_marker))end_marker="FPR EXIT 0";
   if(!$value$plusargs("START=%s",start_marker))start_marker="DTREE DATA READY";
   forever begin
     @(negedge uart_tx);
     repeat(UART_BIT/2)@(posedge clk);
     for(bit_index=0;bit_index<8;bit_index=bit_index+1)begin
       repeat(UART_BIT)@(posedge clk);received[bit_index]=uart_tx;
     end
     repeat(UART_BIT)@(posedge clk);
     $write("%c",received);$fflush;
     if(received==10)begin
       // Whole-line matches: line_text is zero above the line's characters.
       if(line_text==start_marker && !measuring)begin measuring=1;window_start=cycles;end
       if(line_text==end_marker)finish_run;
       line_text=0;line_length=0;
     end else begin line_text={line_text[8*63-1:0],received};line_length=line_length+1;end
   end
 end

 reg [4095:0] image_file;integer words,i;reg [63:0] limit;
 initial begin
   if(!$value$plusargs("IMAGE=%s",image_file) || !$value$plusargs("WORDS=%d",words))$fatal(1,"missing image/word count");
   if(!$value$plusargs("TEXT_END=%d",text_end_word))text_end_word=0;
   if(!$value$plusargs("LIMIT=%d",limit))limit=64'd400000000;
   for(i=0;i<2097152;i=i+1)ram[i]=0;
   $readmemh(image_file,ram,0,words-1);
   repeat(5)@(negedge clk);reset=0;
   wait(cycles>=limit);
   $display("\nPERF LIMIT reached");
   finish_run;
 end
endmodule
