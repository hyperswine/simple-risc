`default_nettype none
// Slow-domain window controller and UART; only the actual probe and the two
// control synchronizers run on clk_core. The probe is frozen before snapshot.
module top(input wire clk_27m, output wire uart_tx);
  parameter integer FREQ_MHZ=216;
  parameter integer BASE_CYCLES=65536;
  parameter integer STARTUP_CYCLES=54000;
  parameter integer SAMPLES=32;
  parameter integer UART_DIV=234;
  wire clk_core,pll_lock;
  probe_pll #(.FBDIV_SEL(47),.IDIV_SEL(5),.ODIV_SEL(4)) pll(.clk_27m(clk_27m),.clk_core(clk_core),.clk_sdram(),.pll_lock(pll_lock));
  reg reset_request=1,run_request=0;
  (* syn_keep=1 *) reg [1:0] reset_sync=3,run_sync=0;
  always @(posedge clk_core) begin
    reset_sync<={reset_sync[0],reset_request | ~pll_lock};
    run_sync<={run_sync[0],run_request};
  end
  wire [31:0] q;
  probe_lfsr probe(.clk(clk_core),.reset(reset_sync[1]),.enable(run_sync[1]),.q(q));
  reg [1:0] lock_sync=0;
  always @(posedge clk_27m) lock_sync<={lock_sync[0],pll_lock};
  reg [3:0] phase=0;
  reg [31:0] count=STARTUP_CYCLES-1,window_cycles=BASE_CYCLES;
  reg [15:0] sample_index=0;
  reg [135:0] frame=0;
  reg [4:0] bytes_left=0;
  reg [9:0] tx_shift=10'h3ff;
  reg [3:0] bits_left=0;
  reg [15:0] baud_count=0;
  localparam [15:0] FREQUENCY=FREQ_MHZ;
  wire [127:0] payload={q,window_cycles,sample_index,FREQUENCY,32'h31485046};
  function [7:0] checksum;
    input [127:0] data;
    integer i;
    begin checksum=0; for(i=0;i<16;i=i+1) checksum=checksum ^ data[i*8+:8]; end
  endfunction
  assign uart_tx=tx_shift[0];
  always @(posedge clk_27m) begin
    if(bits_left!=0) begin
      if(baud_count==0) begin
        tx_shift<={1'b1,tx_shift[9:1]}; bits_left<=bits_left-1; baud_count<=UART_DIV-1;
      end else baud_count<=baud_count-1;
    end
    if(!lock_sync[1]) begin
      reset_request<=1;run_request<=0;phase<=0;count<=STARTUP_CYCLES-1;
    end else begin
      case(phase)
        0: if(count==0) begin reset_request<=0;count<=31;phase<=1;end else count<=count-1;
        1: if(count==0) begin run_request<=1;count<=window_cycles-1;phase<=2;end else count<=count-1;
        2: if(count==0) begin run_request<=0;count<=31;phase<=3;end else count<=count-1;
        3: if(count==0) begin frame<={checksum(payload),payload};bytes_left<=17;phase<=4;end else count<=count-1;
        4: if(bits_left==0) begin
             if(bytes_left!=0) begin
               tx_shift<={1'b1,frame[7:0],1'b0};bits_left<=10;baud_count<=UART_DIV-1;
               frame<={8'd0,frame[135:8]};bytes_left<=bytes_left-1;
             end else if(sample_index==SAMPLES-1) phase<=5;
             else begin
               sample_index<=sample_index+1;window_cycles<=window_cycles+256;
               reset_request<=1;count<=31;phase<=0;
             end
           end
        default: begin end
      endcase
    end
  end
endmodule
