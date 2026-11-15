`default_nettype none
module top(input wire clk_27m, output wire uart_tx);
 wire clk_core,pll_lock;
 probe_pll #(.FBDIV_SEL(47),.IDIV_SEL(5),.ODIV_SEL(4)) pll(.clk_27m(clk_27m),.clk_core(clk_core),.clk_sdram(),.pll_lock(pll_lock));
 reg [1:0] reset_pipe=3;
 always @(posedge clk_core) reset_pipe<={reset_pipe[0],~pll_lock};
 wire [31:0] q;
 probe_bram probe(.clk(clk_core),.reset(reset_pipe[1]),.enable(1'b1),.q(q));
 reg [31:0] observed=0;
 always @(posedge clk_core) observed<=q;
 assign uart_tx=^observed;
endmodule
