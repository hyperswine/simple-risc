`default_nettype none
// Continuous LFSR with periodic held snapshots. No run/stop enable feeds
// the probe. The slow domain checks successive snapshots 256 core cycles apart.
module top(input wire clk_27m, output wire uart_tx);
  parameter integer FREQ_MHZ=216;
  parameter integer BASE_CYCLES=65536;
  parameter integer STARTUP_CYCLES=54000;
  parameter integer SAMPLES=32;
  parameter integer UART_DIV=234;
  wire clk_core,pll_lock;
  PLL_INSTANCE
  (* syn_keep=1 *) reg [1:0] reset_sync=3;
  always @(posedge clk_core) reset_sync<={reset_sync[0],~pll_lock};
  wire [31:0] q;
  PROBE_MODULE probe(.clk(clk_core),.reset(reset_sync[1]),.enable(1'b1),.q(q));
  reg [7:0] capture_count=0;
  reg low_match=0,high_match=0;
  reg capture_due=0;
  reg [31:0] held=0;
  reg capture_toggle=0;
  always @(posedge clk_core) begin
    if(reset_sync[1]) begin capture_count<=0;low_match<=0;high_match<=0;capture_due<=0;capture_toggle<=0;held<=0;end
    else begin
      capture_count<=capture_count+1'b1;
      low_match<=capture_count[3:0]==13;
      high_match<=capture_count[7:4]==15;
      capture_due<=low_match && high_match;
      if(capture_due) begin held<=q;capture_toggle<=~capture_toggle;end
    end
  end
  (* syn_keep=1 *) reg [2:0] capture_sync=0;
  always @(posedge clk_27m) capture_sync<={capture_sync[1:0],capture_toggle};
  wire capture_event=capture_sync[2]^capture_sync[1];
  reg [31:0] first=0,second=0;
  reg [1:0] lock_sync=0;
  always @(posedge clk_27m) lock_sync<={lock_sync[0],pll_lock};
  reg [3:0] phase=0;
  reg [31:0] count=STARTUP_CYCLES-1,window_cycles=BASE_CYCLES;
  reg [15:0] sample_index=0;
  reg [167:0] frame=0;
  reg [4:0] bytes_left=0;
  reg [9:0] tx_shift=10'h3ff;
  reg [3:0] bits_left=0;
  reg [15:0] baud_count=0;
  localparam [15:0] FREQUENCY=FREQ_MHZ;
  wire [159:0] payload={second,first,32'd256,sample_index,FREQUENCY,32'h31435046};
  function [7:0] checksum;
    input [159:0] data;
    integer i;
    begin checksum=0; for(i=0;i<20;i=i+1) checksum=checksum ^ data[i*8+:8]; end
  endfunction
  assign uart_tx=tx_shift[0];
  always @(posedge clk_27m) begin
    if(bits_left!=0) begin
      if(baud_count==0) begin
        tx_shift<={1'b1,tx_shift[9:1]}; bits_left<=bits_left-1; baud_count<=UART_DIV-1;
      end else baud_count<=baud_count-1;
    end
    if(!lock_sync[1]) begin
      phase<=0;count<=STARTUP_CYCLES-1;
    end else begin
      case(phase)
        0: if(count==0) phase<=1; else count<=count-1;
        1: if(capture_event) begin first<=held;phase<=2;end
        2: if(capture_event) begin second<=held;phase<=3;end
        3: begin frame<={checksum(payload),payload};bytes_left<=21;phase<=4;end
        4: if(bits_left==0) begin
             if(bytes_left!=0) begin
               tx_shift<={1'b1,frame[7:0],1'b0};bits_left<=10;baud_count<=UART_DIV-1;
               frame<={8'd0,frame[167:8]};bytes_left<=bytes_left-1;
             end else if(sample_index==SAMPLES-1) phase<=5;
             else begin
               sample_index<=sample_index+1;phase<=1;
             end
           end
        default: begin end
      endcase
    end
  end
endmodule
