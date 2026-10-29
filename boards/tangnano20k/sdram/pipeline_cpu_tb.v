`timescale 1ns/1ps
module pipeline_cpu_tb #(
 parameter ROM_FILE="output/tangnano20k/pipeline-rtl/rom.hex",
 parameter EXPECT_TRAPS=4,
 parameter LINE_BITS=12,
 parameter CACHE_WAYS=1,
 parameter LOADER_TEST=0,
 parameter UART_BIT=868,
 parameter PIN_MODEL=0,
 parameter CDC_BRIDGE=0,
 parameter LOADER_DUMP=0,
 parameter LOADER_EXTENDED=0,
 parameter LOADER_FRAMED=0,
 parameter LOADER_UPLOAD_ONLY=0,
 parameter LOADER_RAW_READBACK=0,
 parameter PIN_FREQ_MHZ=48,
 parameter real PIN_PHASE_DEGREES=180.0,
 parameter real PIN_TAC_NS=0.0
);
 localparam STATUS=21'h180000,BOOT_COUNT=21'h1ffc00;
 localparam COUNTER_LINE=21'h140000,LONG_LINE=21'h0c0000;
 localparam EFFECT_WORD=21'h180040;
 localparam real CLOCK_NS=PIN_MODEL ? 1000.0/PIN_FREQ_MHZ/(CDC_BRIDGE ? 2.0:1.0):10.0;
 localparam real MEMORY_CLOCK_NS=CLOCK_NS*(CDC_BRIDGE ? 2.0:1.0);
 reg clk=0;always #(CLOCK_NS/2.0) clk=~clk;
 reg reset=1,uart_rx=1;
 // The optional mailbox leg uses a deliberately offset memory clock.
 // Resets share assertion and release synchronously in each domain.
 reg slower_clk=0;
 initial begin #(CLOCK_NS*0.313);forever #CLOCK_NS slower_clk=~slower_clk;end
 wire backend_clk=CDC_BRIDGE ? slower_clk:clk;
 reg [1:0] cpu_reset_pipe=3,mem_reset_pipe=3;
 always @(posedge clk or posedge reset)if(reset)cpu_reset_pipe<=3;else cpu_reset_pipe<={cpu_reset_pipe[0],1'b0};
 always @(posedge backend_clk or posedge reset)if(reset)mem_reset_pipe<=3;else mem_reset_pipe<={mem_reset_pipe[0],1'b0};
 wire backend_reset=CDC_BRIDGE ? mem_reset_pipe[1]:reset;
 wire core_reset=CDC_BRIDGE ? cpu_reset_pipe[1]:reset;
 wire uart_tx,hold_cpu,cpu_write;
 wire sd_sck,sd_mosi,sd_cs;
 wire [21:0] cpu_address;wire [31:0] cpu_wdata,cpu_rdata;
 wire [3:0] cpu_mask;
 sdram_pipeline_risc cpu(.clk(clk),.reset(core_reset),.enable(1'b1),
   .uart_rx(uart_rx),.uart_tx(uart_tx),.memory_data(cpu_rdata),.memory_hold(hold_cpu),
   .memory_address(cpu_address),.memory_write(cpu_write),.memory_wdata(cpu_wdata),.memory_mask(cpu_mask),
   .sd_miso(sd_mosi),.sd_sck(sd_sck),.sd_mosi(sd_mosi),.sd_cs(sd_cs));
 // Named simulation-only ports from SdramPipelineObserved. No generated
 // internal identifier or Machine/Pipe bit offset is part of this contract.
 pipeline_fence_assertions fence_i_monitor(clk,core_reset,hold_cpu,
   cpu.observe_commit,cpu.observe_word,cpu.observe_pc,cpu.observe_next_pc,
   cpu.observe_issue,cpu.observe_fetch_pc,cpu.observe_empty);
 wire req,write,ready;wire [20:0] address;wire [31:0] wdata;wire [3:0] mask;
 wire done,valid;wire [31:0] rdata;wire [1:0] word_index;
 wire c_req,c_write,c_ready,c_done,c_valid;
 wire [20:0] c_address;wire [31:0] c_wdata,c_rdata;wire [3:0] c_mask;wire [1:0] c_word_index;
 reg fake_done=0,fake_valid=0;reg [31:0] fake_rdata=0;reg [1:0] fake_word_index=0;
 sdram_pipeline_cache #(.LINE_BITS(LINE_BITS),.WAYS(CACHE_WAYS),.ROM_FILE(ROM_FILE)) cache(clk,core_reset,
   cpu_address,cpu_write,cpu_wdata,cpu_mask,hold_cpu,cpu_rdata,
   c_req,c_write,c_address,c_wdata,c_mask,c_ready,c_done,c_rdata,c_valid,c_word_index);
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

 reg [31:0] ram[0:2097151];
 reg [31:0] expected_image[0:16383];
 integer i,words,send_index;reg [4095:0] image_file;
 reg probe_finished=0,verify_finished=0;
 reg [31:0] expected_xor=0;
 // Framed ('U') upload: the CRC-32s the host would send, and the reply state.
 // crc32_update is the reflected byte-wise form, which is what the ROM's
 // word-wise crc32_word computes over a little-endian word.
 reg [31:0] expected_header_crc=0,expected_payload_crc=0;
 reg identity_finished=0,upload_finished=0,readback_finished=0;
 integer readback_count=0,read_index;
 integer raw_lines=0,raw_footer_index=0;reg raw_finished=0;
 reg [47:0] framed_head=0;reg [23:0] framed_three=0;reg [47:0] framed_six=0;
 reg [127:0] framed_msg=0;integer framed_len=0;
 integer tick=0,backend_tick=0,delay=0,phase=0,reads=0,writes=0,held_clocks=0;
 integer long_held=0,ready_stalls=0,markers=0,quiet=0;
 integer timer_misses=0;
 reg saved_write=0,long_seen=0,break_sent=0,corrupt=0;
 reg [20:0] saved_address=0;reg [31:0] saved_data=0;reg [3:0] saved_mask=0;
 integer lane;
 integer effect_stores[0:7],effect_commits[0:7];
 integer effect_held_clocks=0,backend_effect_index,commit_effect_index,effect_init;
 initial for(effect_init=0;effect_init<8;effect_init=effect_init+1)begin
   effect_stores[effect_init]=0;effect_commits[effect_init]=0;
 end
 reg [31:0] effect_once_pc=0,effect_padding_pc=0,effect_skip_pc=0;
 // Count external acceptance and architectural retirement separately. Memory
 // writes can be queued across a hold; a repeated identical write would be
 // invisible in final RAM data, so it must be counted at this handshake.
 always @(posedge backend_clk)begin
   if(!LOADER_TEST && !backend_reset && req && ready && write)begin
     if(address>=EFFECT_WORD && address<EFFECT_WORD+8)begin
       backend_effect_index=address-EFFECT_WORD;
       if(effect_stores[backend_effect_index]!=0)$fatal(1,"duplicate owned store");
       if(wdata!==32'h71e77e55 || mask!==4'hf)$fatal(1,"owned store payload changed");
       effect_stores[backend_effect_index]<=effect_stores[backend_effect_index]+1;
     end
     if(address==EFFECT_WORD+8)$fatal(1,"cancelled store reached memory");
   end
 end
 always @(posedge clk)begin
   if(!LOADER_TEST && !core_reset && hold_cpu &&
      ((cpu.observe_pc>=effect_once_pc && cpu.observe_pc<effect_once_pc+32) ||
       (cache.v2 && cache.w2 && cache.a2>={1'b0,EFFECT_WORD} && cache.a2<{1'b0,EFFECT_WORD}+8)))
     effect_held_clocks<=effect_held_clocks+1;
   if(!LOADER_TEST && !core_reset && !hold_cpu && cpu.observe_commit &&
      cpu.observe_pc>=effect_once_pc && cpu.observe_pc<effect_once_pc+32)begin
     commit_effect_index=(cpu.observe_pc-effect_once_pc)>>2;
     if(effect_commits[commit_effect_index]!=0)$fatal(1,"duplicate owned retirement");
     effect_commits[commit_effect_index]<=effect_commits[commit_effect_index]+1;
   end
 end
 always @(posedge clk)begin
   tick<=tick+1;
   if(!reset && hold_cpu)held_clocks<=held_clocks+1;
   if(!reset && hold_cpu && long_seen && !break_sent)long_held<=long_held+1;
   if(req && !ready)ready_stalls<=ready_stalls+1;
 end
 always @(posedge backend_clk)backend_tick<=backend_tick+1;
 generate if(!PIN_MODEL)begin: delayed_backend
 assign ready=!backend_reset && delay==0 && phase==0 && backend_tick%7!=0;
 assign done=fake_done;assign valid=fake_valid;assign rdata=fake_rdata;assign word_index=fake_word_index;
 always @(posedge backend_clk)begin
   fake_done<=0;fake_valid<=0;
   if(req && ready)begin
     saved_write<=write;saved_address<=address;saved_data<=wdata;saved_mask<=mask;
     delay<=12+backend_tick%13;
     if(write)writes<=writes+1;
     else begin
       reads<=reads+1;
       if(address[1:0]!=0)$fatal(1,"unaligned line refill %h",address);
       if(address==COUNTER_LINE)delay<=1000;
       if(address>=21'h144000 && address<21'h164000)begin
         delay<=5000;timer_misses<=timer_misses+1;
       end
       if(address==LONG_LINE && ram[STATUS]==32'h600d0001 && !long_seen)begin
         delay<=12000;long_seen<=1;
       end
     end
   end else if(delay>0)begin
     delay<=delay-1;
     if(delay==1)begin
       if(saved_write)begin
         for(lane=0;lane<4;lane=lane+1)
           if(saved_mask[lane])ram[saved_address][lane*8+:8]<=saved_data[lane*8+:8];
         fake_done<=1;
       end else phase<=1;
     end
   end else if(phase!=0 && backend_tick%3!=0)begin
     // Uneven gaps between each beat exercise valid/index/data independently.
     if(phase<=4)begin
       fake_rdata<=ram[saved_address+phase-1] ^ ((corrupt && saved_address==COUNTER_LINE && phase==1) ? 1:0);
       fake_word_index<=phase-1;fake_valid<=1;phase<=phase+1;
     end else begin fake_done<=1;phase<=0;end
   end
 end
 end else begin: physical_backend
   wire sclk,cke,cs_n,cas_n,ras_n,we_n;
   wire [3:0] dqm;wire [10:0] sa;wire [1:0] ba;tri [31:0] dq;
   reg phase_clk=0;
   // Transport the core clock edges, including phases exceeding 180 degrees.
   // A delayed continuous assignment would reject pulses at those delays.
   always @(backend_clk)phase_clk<=#(MEMORY_CLOCK_NS*PIN_PHASE_DEGREES/360.0)backend_clk;
   sdram_burst_memory #(.FREQ(PIN_FREQ_MHZ*1000000)) mem(backend_clk,phase_clk,backend_reset,req,write,address,wdata,mask,
     ready,done,rdata,valid,word_index,sclk,cke,cs_n,cas_n,ras_n,we_n,dqm,sa,ba,dq);
   reg [10:0] open_row[0:3];reg [3:0] bank_open=0;
   reg [10:0] mode=0;reg configured=0;
   reg drive=0;reg [31:0] pin_data=0;
   // A functional output-access delay. This excludes FPGA I/O routing,
   // command setup/hold, jitter and PVT, so it is not an I/O timing signoff.
   assign #(PIN_TAC_NS) dq=drive ? pin_data:32'bz;
   integer read_delay=0,read_beat=0,pin_lane,physical_word;
   reg active_read=0;reg [20:0] read_base;reg [1:0] read_bank;
   reg [20:0] capture_base;
   always @(posedge backend_clk)begin
     if(req && ready)begin
       if(write)writes<=writes+1;
       else begin reads<=reads+1;capture_base<=address;end
     end
     if(!backend_reset && valid && rdata!==ram[capture_base+word_index])
       $fatal(1,"SDRAM capture word %h beat%0d=%h expected=%h",capture_base,word_index,rdata,ram[capture_base+word_index]);
   end
   // Micron 256MSDRAM_G p13, CAS Latency: after READ at edge N, DQ starts
   // driving after N+CAS-1 and is valid by N+CAS. The optional tAC delay
   // models output access after that earlier edge, not an extra full clock.
   // https://people.eecs.berkeley.edu/~kubitron/courses/cs152-S04/handouts/256MSDRAM_G.pdf
   // Consecutive beats and real completion replace the gapped backend.
   always @(posedge sclk)begin
     if(backend_reset)begin active_read=0;read_delay=0;read_beat=0;drive=0;bank_open=0;configured=0;mode=0;end
     else begin
       if(cke!==1 || cs_n!==0)$fatal(1,"SDRAM select/CKE");
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
         3'b001:if(bank_open!=0 || active_read || drive)$fatal(1,"SDRAM refresh overlaps burst");
         3'b000:begin
           if(sa!==11'h222 || ba!==0 || bank_open!=0)$fatal(1,"SDRAM mode set %h bank%0d",sa,ba);
           mode=sa;configured=1;
         end
         3'b011:begin
           if(!configured || bank_open[ba] || active_read || drive)$fatal(1,"SDRAM activation overlap");
           open_row[ba]=sa;bank_open[ba]=1;
         end
         3'b101:begin
           if(!configured || !bank_open[ba] || active_read || drive)$fatal(1,"SDRAM read without activation");
           if(sa[10]!==1 || sa[9:8]!==0 || sa[1:0]!==0 || dqm!==0)$fatal(1,"SDRAM read alignment/mask");
           read_base={ba,open_row[ba],sa[7:0]};read_bank=ba;read_delay=mode[6:4]-1;read_beat=0;active_read=1;
         end
         3'b100:begin
           if(!configured || !mode[9] || !bank_open[ba] || active_read || drive)$fatal(1,"SDRAM write without activation");
           if(sa[10]!==1 || sa[9:8]!==0)$fatal(1,"SDRAM write column/precharge");
           physical_word={ba,open_row[ba],sa[7:0]};
           for(pin_lane=0;pin_lane<4;pin_lane=pin_lane+1)if(!dqm[pin_lane])begin
             if((^dq[pin_lane*8+:8])===1'bx)$fatal(1,"SDRAM unknown write data");
             ram[physical_word][pin_lane*8+:8]=dq[pin_lane*8+:8];
           end
           bank_open[ba]=0;
         end
         default:$fatal(1,"unsupported SDRAM pin command");
       endcase
     end
   end
 end endgenerate

 task send_byte(input [7:0] byte_value);
 integer bit_number;
 begin
   @(negedge clk);uart_rx=0;
   repeat(UART_BIT)@(negedge clk);
   for(bit_number=0;bit_number<8;bit_number=bit_number+1)begin
     uart_rx=byte_value[bit_number];repeat(UART_BIT)@(negedge clk);
   end
   uart_rx=1;repeat(UART_BIT)@(negedge clk);
 end endtask
 task send_word32(input [31:0] value);
 begin
   send_byte(value[7:0]);send_byte(value[15:8]);send_byte(value[23:16]);send_byte(value[31:24]);
 end endtask
 function [31:0] crc32_update;
   input [31:0] crc_in;
   input [7:0] data;
   integer k;
   reg [31:0] c;
   begin
     c=crc_in^{24'h000000,data};
     for(k=0;k<8;k=k+1)c=c[0] ? ((c>>1)^32'hEDB88320):(c>>1);
     crc32_update=c;
   end
 endfunction
 initial begin
   if(LOADER_TEST)begin
     wait(!reset);repeat(2000)@(negedge clk);
     if(LOADER_FRAMED)begin
       // 'I', then the 'U' frame, then 'C' readback, then a guarded 'G' run.
       send_byte(8'h49);
       wait(identity_finished);repeat(UART_BIT)@(negedge clk);
       send_byte(8'h55);
       send_word32(32'h31555253);
       send_word32(words[31:0]);
       send_word32(expected_header_crc);
       for(send_index=0;send_index<words*4;send_index=send_index+1)
         send_byte(expected_image[send_index/4] >> ((send_index%4)*8));
       send_word32(expected_payload_crc);
       wait(upload_finished);repeat(UART_BIT)@(negedge clk);
       for(read_index=0;read_index<(LOADER_UPLOAD_ONLY ? 3:1);read_index=read_index+1)begin
         send_byte(8'h43);
         wait(readback_count>read_index);repeat(UART_BIT)@(negedge clk);
       end
       if(LOADER_UPLOAD_ONLY)begin
         if(LOADER_RAW_READBACK)begin send_byte(8'h44);wait(raw_finished);end
         wait(cache.write_count==0 && cache.state==0);
         @(negedge clk);
         for(j=0;j<words;j=j+1)if(ram[j]!==expected_image[j])$fatal(1,"upload-only backing word %0d mismatch",j);
         if(ram[words]!==0)$fatal(1,"upload-only missing zero sentinel");
         $display("PASS: ROM I/U/C upload-only, three readback CRCs and backing memory; no guest executed");
         $finish;
       end else send_byte(8'h47);
     end else begin
     if(LOADER_EXTENDED)begin
       send_byte(8'h54);wait(probe_finished);repeat(UART_BIT)@(negedge clk);
     end
     send_byte(LOADER_EXTENDED ? 8'h51:8'h50);send_byte(words[7:0]);send_byte(words[15:8]);
     if(LOADER_EXTENDED)begin send_byte(words[23:16]);send_byte(words[31:24]);end
     for(send_index=0;send_index<words*4;send_index=send_index+1)
       send_byte(expected_image[send_index/4] >> ((send_index%4)*8));
     if(LOADER_EXTENDED)begin
       send_byte(8'h56);wait(verify_finished);repeat(UART_BIT)@(negedge clk);
     end
     send_byte(LOADER_DUMP ? 8'h44:LOADER_EXTENDED ? 8'h48:8'h52);
     end
   end else begin
     wait(long_seen);repeat(3)@(negedge clk);
     send_byte(8'h03);break_sent=1;
   end
 end
 reg [7:0] transmitted;integer bit_number,j;
 reg [31:0] last_four=0;
 reg [31:0] dump_value=0;integer dump_digits=0,dump_lines=0,nibble;
 initial forever begin
   @(negedge uart_tx);
   repeat(UART_BIT+UART_BIT/2)@(posedge clk);
   for(bit_number=0;bit_number<8;bit_number=bit_number+1)begin
     transmitted[bit_number]=uart_tx;repeat(UART_BIT)@(posedge clk);
   end
   if(uart_tx!==1)$fatal(1,"UART framing");
   if(LOADER_TEST)begin
     $write("%c",transmitted);$fflush;
     if(LOADER_FRAMED && !readback_finished)begin
       framed_head={framed_head[39:0],transmitted};
       framed_msg={framed_msg[119:0],transmitted};
       framed_len=framed_len+1;
       if(framed_len==3)framed_three=framed_head[23:0];
       if(framed_len==6)framed_six=framed_head[47:0];
       // 'O', 'K', 'E', 'R' and ' ' are not hex digits, so only a CRC field
       // accumulates here; gating on identity_finished skips the identity
       // line's own hex (cpu=, mem=, ram=, max=, id=).
       if(identity_finished &&
          ((transmitted>=48 && transmitted<=57)||(transmitted>=97 && transmitted<=102)))begin
         nibble=(transmitted<=57)?transmitted-48:transmitted-87;
         dump_value={dump_value[27:0],nibble[3:0]};dump_digits=dump_digits+1;
       end
       if(transmitted==10)begin
         if(!identity_finished)begin
           if(framed_six!=="SRID1 ")$fatal(1,"ROM identity line is not SRID1: %s",framed_msg);
           identity_finished=1;
         end else if(!upload_finished)begin
           if(framed_three!=="OK ")$fatal(1,"ROM rejected the framed upload: %s",framed_msg);
           if(dump_digits!=8 || dump_value!==expected_payload_crc)
             $fatal(1,"ROM upload ack CRC=%h expected=%h digits=%0d",dump_value,expected_payload_crc,dump_digits);
           upload_finished=1;dump_value=0;dump_digits=0;
         end else begin
           if(dump_digits!=8 || dump_value!==expected_payload_crc)
             $fatal(1,"ROM 'C' readback CRC=%h expected=%h digits=%0d",dump_value,expected_payload_crc,dump_digits);
           readback_count=readback_count+1;
           if(!LOADER_UPLOAD_ONLY || readback_count==3)readback_finished=1;
           dump_value=0;dump_digits=0;
         end
         framed_head=0;framed_msg=0;framed_len=0;
       end
     end else if(LOADER_RAW_READBACK && readback_finished && !raw_finished)begin
       if(raw_lines<=words)begin
         if(transmitted==10)begin
           if(dump_digits!=8)$fatal(1,"raw readback needs exactly eight hex digits");
           if(raw_lines==0)begin
             if(dump_value!==words[31:0])$fatal(1,"raw readback count mismatch");
           end else if(dump_value!==expected_image[raw_lines-1])
             $fatal(1,"raw readback word %0d=%h expected=%h",raw_lines-1,dump_value,expected_image[raw_lines-1]);
           raw_lines=raw_lines+1;dump_value=0;dump_digits=0;last_four=0;
         end else begin
           if(transmitted>=48 && transmitted<=57)nibble=transmitted-48;
           else if(transmitted>=97 && transmitted<=102)nibble=transmitted-87;
           else $fatal(1,"raw readback nonhex output");
           dump_value={dump_value[27:0],nibble[3:0]};dump_digits=dump_digits+1;
         end
       end else begin
         if((raw_footer_index==0 && transmitted!=8'h45) ||
            (raw_footer_index==1 && transmitted!=8'h4e) ||
            (raw_footer_index==2 && transmitted!=8'h44) ||
            (raw_footer_index==3 && transmitted!=8'h0a))$fatal(1,"raw readback footer mismatch");
         if(raw_footer_index==3)raw_finished=1;
         raw_footer_index=raw_footer_index+1;
       end
     end else if(LOADER_EXTENDED && !probe_finished)begin
       last_four={last_four[23:0],transmitted};
       if(last_four=="DONE")begin probe_finished=1;last_four=0;end
     end else if(LOADER_EXTENDED && !verify_finished)begin
       if(transmitted==10)begin
         if(dump_digits!=8 || dump_value!==expected_xor)$fatal(1,"ROM XOR=%h expected=%h digits=%0d",dump_value,expected_xor,dump_digits);
         verify_finished=1;
       end else begin
         if(transmitted>=48 && transmitted<=57)nibble=transmitted-48;
         else if(transmitted>=97 && transmitted<=102)nibble=transmitted-87;
         else $fatal(1,"ROM XOR nonhex output %h",transmitted);
         dump_value={dump_value[27:0],nibble[3:0]};dump_digits=dump_digits+1;
       end
     end else if(LOADER_DUMP)begin
       if(transmitted==10)begin
         if(dump_digits!=8 || dump_value!==ram[dump_lines])$fatal(1,"debug ROM dump word%0d=%h backing=%h digits=%0d",dump_lines,dump_value,ram[dump_lines],dump_digits);
         dump_value=0;dump_digits=0;dump_lines=dump_lines+1;
         if(dump_lines==8)begin
           for(j=0;j<words;j=j+1)if(ram[j]!==expected_image[j])$fatal(1,"ROM uploaded word %0d mismatch",j);
           if(ram[words]!==0)$fatal(1,"ROM did not append zero sentinel");
           $display("PASS: debug ROM memory dump matches eight backing words");$finish;
         end
       end else begin
         if(transmitted>=48 && transmitted<=57)nibble=transmitted-48;
         else if(transmitted>=97 && transmitted<=102)nibble=transmitted-87;
         else $fatal(1,"debug ROM nonhex output %h",transmitted);
         dump_value={dump_value[27:0],nibble[3:0]};dump_digits=dump_digits+1;
       end
     end else begin
     if(transmitted==8'h4c)markers=markers+1;
     last_four={last_four[23:0],transmitted};
     if(last_four=="DONE")begin
       if(markers!=1)$fatal(1,"ROM DONE without guest marker; RAM %h %h %h %h expected %h %h %h %h",
         ram[0],ram[1],ram[2],ram[3],expected_image[0],expected_image[1],expected_image[2],expected_image[3]);
       for(j=0;j<words;j=j+1)if(ram[j]!==expected_image[j])$fatal(1,"ROM uploaded word %0d mismatch",j);
       if(ram[words]!==0)$fatal(1,"ROM did not append zero sentinel");
       if(LOADER_FRAMED)$display("\nPASS: ROM I/U/C/G framed upload, CRC32 ack and readback, guarded execution and trap DONE");
       else if(LOADER_EXTENDED)$display("\nPASS: extended ROM T/Q/V/H UART loader, XOR readback, program execution and trap DONE");
       else $display("\nPASS: actual ROM UART loader, program execution and trap DONE");
       $finish;
     end
     end
   end else begin
     if((markers==0 && transmitted!=8'h50) || (markers==1 && transmitted!=8'h52) || markers>1)
       $fatal(1,"UART marker %0d unexpected %h",markers,transmitted);
     markers=markers+1;
   end
 end

 always @(negedge clk)begin
   if(!LOADER_TEST && !reset && ram[STATUS]===32'hbad00001)
     $fatal(1,"guest failure stage=%0d cycles=%0d retired=%0d",ram[STATUS+1],ram[STATUS+2],ram[STATUS+3]);
   if(!LOADER_TEST && !reset && ram[STATUS]===32'h600d0002 && markers==2 && cache.write_count==0 && cache.state==0)begin
     quiet=quiet+1;
     if(quiet==8)begin
       if(ram[BOOT_COUNT]!==2)$fatal(1,"Ctrl-C did not restart through ROM");
       if(ram[21'h080000]!==32'hbbccaa44)$fatal(1,"masked write/physical +2MiB");
       if(ram[21'h100000]!==32'hdeadbeef)$fatal(1,"physical +4MiB alias");
       if(ram[21'h1fffff]!==32'habcdef01)$fatal(1,"last SDRAM word");
       if(ram[21'h080400]!==32'h02b00513 || ram[21'h080401]!==32'h00008067)$fatal(1,"instruction patch backing data");
       if(ram[STATUS+4]!==32'hbbccaa44)$fatal(1,"forwarded partial result");
       for(j=0;j<8;j=j+1)
         if(effect_stores[j]!=1 || effect_commits[j]!=1 || ram[EFFECT_WORD+j]!==32'h71e77e55)
           $fatal(1,"effect ownership coverage slot=%0d stores=%0d commits=%0d",j,effect_stores[j],effect_commits[j]);
       if(effect_held_clocks==0 || ram[EFFECT_WORD+8]!==0)$fatal(1,"effect ownership hold/cancellation coverage");
       if(ram[STATUS+5]!==5691265)$fatal(1,"branch/multiply loop");
       if(ram[STATUS+6]!==EXPECT_TRAPS)$fatal(1,"precise trap count");
       if(ram[STATUS+2]<1000 || ram[STATUS+3]==0 || ram[STATUS+3]>=64)$fatal(1,"hold/counter contract");
       if(ram[STATUS+7]<1000)$fatal(1,"mtime did not advance across memory hold");
       if(timer_misses!=8 || ram[STATUS+8]!==8 || ram[STATUS+9]!==32'h5a5a1234)
         $fatal(1,"timer/cache/flush coverage misses=%0d interrupts=%0d sentinel=%h",timer_misses,ram[STATUS+8],ram[STATUS+9]);
       if(!break_sent || long_held<8000 || ready_stalls==0)$fatal(1,"hold/backpressure/UART leg was not exercised");
       if(fence_i_monitor.commits<2 || fence_i_monitor.memory_fetches!=fence_i_monitor.commits ||
         fence_i_monitor.verified_fences!=fence_i_monitor.commits || fence_i_monitor.awaiting_memory_fetch ||
         fence_i_monitor.awaiting_commit)$fatal(1,"FENCE.I coverage commits=%0d fetches=%0d verified=%0d pending=%b/%b",
         fence_i_monitor.commits,fence_i_monitor.memory_fetches,fence_i_monitor.verified_fences,
         fence_i_monitor.awaiting_memory_fetch,fence_i_monitor.awaiting_commit);
       $display("PASS: pipeline/cache guest, high RAM, masked stores, fence.i, IM/branches/traps, eight timer interrupts across misses, counters and Ctrl-C; %0d fills %0d writes %0d held clocks; %0d fence.i epoch assertions; eight owned stores/retirements accepted once each, no cancelled store, %0d owned-effect hold clocks",reads,writes,held_clocks,fence_i_monitor.verified_fences,effect_held_clocks);
       $finish;
     end
   end else quiet=0;
 end
 // Guest mutations also support a 32-bit instruction crossing a word boundary
 // in an RV32C guest. Keep the surrounding halfwords intact.
 function [31:0] instruction_at(input [31:0] pc);
 integer index;
 begin
   index=(pc-32'h80000000)>>2;
   instruction_at=pc[1] ? {ram[index+1][15:0],ram[index][31:16]}:ram[index];
 end
 endfunction
 task patch_instruction(input [31:0] pc,input [31:0] instruction);
 integer index;
 begin
   index=(pc-32'h80000000)>>2;
   if(pc[1])begin ram[index][31:16]=instruction[15:0];ram[index+1][15:0]=instruction[31:16];end
   else ram[index]=instruction;
 end
 endtask
 initial begin
   corrupt=$test$plusargs("CORRUPT");
   if(!$value$plusargs("IMAGE=%s",image_file) || !$value$plusargs("WORDS=%d",words))$fatal(1,"missing image/word count");
   for(i=0;i<2097152;i=i+1)ram[i]=LOADER_TEST ? 32'h1f3d5b79^(i*32'h10204081)^(i<<11):0;
   if(LOADER_TEST)begin
     $readmemh(image_file,expected_image,0,words-1);
     for(i=0;i<words;i=i+1)expected_xor=expected_xor^expected_image[i];
     if(LOADER_FRAMED)begin
       // Header CRC over the eight bytes "SRU1" + count, then the payload CRC
       // over the image's little-endian bytes: what frame_u() sends.
       expected_header_crc=32'hFFFFFFFF;
       expected_header_crc=crc32_update(expected_header_crc,8'h53);
       expected_header_crc=crc32_update(expected_header_crc,8'h52);
       expected_header_crc=crc32_update(expected_header_crc,8'h55);
       expected_header_crc=crc32_update(expected_header_crc,8'h31);
       expected_header_crc=crc32_update(expected_header_crc,words[7:0]);
       expected_header_crc=crc32_update(expected_header_crc,words[15:8]);
       expected_header_crc=crc32_update(expected_header_crc,words[23:16]);
       expected_header_crc=crc32_update(expected_header_crc,words[31:24]);
       expected_header_crc=~expected_header_crc;
       expected_payload_crc=32'hFFFFFFFF;
       for(i=0;i<words*4;i=i+1)
         expected_payload_crc=crc32_update(expected_payload_crc,expected_image[i/4] >> ((i%4)*8));
       expected_payload_crc=~expected_payload_crc;
     end
   end
   else begin
     $readmemh(image_file,ram,0,words-1);
     if(!$value$plusargs("EFFECT_ONCE=%h",effect_once_pc) ||
        !$value$plusargs("EFFECT_PADDING=%h",effect_padding_pc) ||
        !$value$plusargs("EFFECT_SKIP=%h",effect_skip_pc))$fatal(1,"missing effect symbols");
     if(effect_once_pc[0] || effect_padding_pc[0] || effect_skip_pc[0])$fatal(1,"effect fixture alignment");
     // Executing the duplicate padding or the cancelled path is a real guest
     // mutation. Final RAM alone cannot detect the identical duplicate write.
     if($test$plusargs("DUPLICATE_EFFECT"))patch_instruction(effect_padding_pc,instruction_at(effect_once_pc));
     if($test$plusargs("WRONG_PATH_EFFECT"))patch_instruction(effect_skip_pc,32'h00000013);
   end
   ram[COUNTER_LINE]=32'h13579bdf;
   repeat(5)@(negedge clk);reset=0;
 end
 initial begin
   // Long pattern uploads use the actual UART divider and three CRC reads.
   // A fixed budget for a tiny loader guest can expire inside a valid frame.
   wait(words>0);
   repeat(LOADER_TEST ? 2000000+(words*4+128)*UART_BIT*12:200000)@(posedge clk);
   $fatal(1,"timeout status=%h stage=%0d boots=%0d cpu=%h hold=%b cache=%0d fills=%0d writes=%0d markers=%0d long=%b",
     ram[STATUS],ram[STATUS+1],ram[BOOT_COUNT],cpu_address,hold_cpu,cache.state,reads,writes,markers,long_seen);
 end
endmodule
