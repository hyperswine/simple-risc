module f1(input clk, input [7:0] a, b, output reg q); always @(posedge clk) q <= a == b; endmodule
module f2(input clk, input [7:0] a, b, output reg q); always @(posedge clk) q <= ~|(a ^ b); endmodule
module f3(input clk, input [7:0] a, b, output reg q); always @(posedge clk) q <= &(a ~^ b); endmodule
module f4(input clk, input [7:0] a, b, output reg q);
 wire lo /* synthesis syn_keep=1 */ = ~|(a[3:0] ^ b[3:0]);
 wire hi /* synthesis syn_keep=1 */ = ~|(a[7:4] ^ b[7:4]);
 always @(posedge clk) q <= lo & hi; endmodule
module f5(input clk, input [7:0] a, b, output reg q);
 (* syn_keep = 1 *) wire lo = ~|(a[3:0] ^ b[3:0]);
 (* syn_keep = 1 *) wire hi = ~|(a[7:4] ^ b[7:4]);
 always @(posedge clk) q <= lo & hi; endmodule
module f6(input clk, input [7:0] a, b, output reg q);
 wire [7:0] x /* synthesis syn_keep=1 */ = a ~^ b;
 always @(posedge clk) q <= &x; endmodule
module f7(input clk, input [7:0] a, b, output reg q);
 wire [3:0] p /* synthesis syn_keep=1 */;
 assign p[0] = a[1:0] == b[1:0]; assign p[1] = a[3:2] == b[3:2]; assign p[2] = a[5:4] == b[5:4]; assign p[3] = a[7:6] == b[7:6];
 always @(posedge clk) q <= &p; endmodule
module f8(input clk, input [7:0] a, b, output reg q);
 // halves through LUT primitives
 wire lo, hi;
 LUT4 l0 (.F(lo), .I0(a[0]), .I1(b[0]), .I2(a[1]), .I3(b[1])); defparam l0.INIT = 16'h9009;
 LUT4 l1 (.F(hi), .I0(a[2]), .I1(b[2]), .I2(a[3]), .I3(b[3])); defparam l1.INIT = 16'h9009;
 always @(posedge clk) q <= lo & hi & (a[7:4] == b[7:4]); endmodule
module f9(input clk, input [7:0] a, b, output reg q);
 // 5-bit compare, the hazard shape
 always @(posedge clk) q <= a[4:0] == b[4:0]; endmodule
module f10(input clk, input [7:0] a, b, output reg q);
 // 4-bit compare: fits one LUT? 8 inputs no; see what synth does
 always @(posedge clk) q <= a[3:0] == b[3:0]; endmodule
module eqtest(input clk, input [7:0] a, b, output [9:0] q);
 reg [7:0] ra, rb; always @(posedge clk) begin ra <= a; rb <= b; end
 f1 u1(clk, ra, rb, q[0]); f2 u2(clk, ra, rb, q[1]); f3 u3(clk, ra, rb, q[2]); f4 u4(clk, ra, rb, q[3]); f5 u5(clk, ra, rb, q[4]);
 f6 u6(clk, ra, rb, q[5]); f7 u7(clk, ra, rb, q[6]); f8 u8(clk, ra, rb, q[7]); f9 u9(clk, ra, rb, q[8]); f10 u10(clk, ra, rb, q[9]);
endmodule
module f11(input clk, input [7:0] a, b, output reg q); always @(posedge clk) q <= &(~(a ^ b)); endmodule
module f12(input clk, input [7:0] a, b, output reg q); always @(posedge clk) q <= &(a[4:0] ~^ b[4:0]); endmodule
module f13(input clk, input [7:0] a, b, output reg q); always @(posedge clk) q <= (&(~(a ^ b))) == 1'b1; endmodule
module f14(input clk, input [7:0] a, b, output reg q); always @(posedge clk) q <= ((~(a ^ b)) == 8'hff); endmodule
module f15(input clk, input [10:0] a, b, output reg q); always @(posedge clk) q <= &(a ~^ b); endmodule
