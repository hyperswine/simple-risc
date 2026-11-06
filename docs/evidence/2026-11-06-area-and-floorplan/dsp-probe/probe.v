// Timing probe: a counter with a CSR-style write, kept in one ALU54D
// accumulator (54 bits) with a 10-bit fabric tail. ACCLOAD=1 accumulates A;
// ACCLOAD=0 loads A. The tail takes the ALU's 55th bit (CASO[54]).
module top(input clk_27m, input din, input load, output dout);
  wire clk = clk_27m;
  reg [63:0] value; reg load_r; reg [9:0] tail; reg out;
  wire [53:0] count; wire [54:0] caso;
  ALU54D alu(.A(load_r ? value[53:0] : 54'd1), .B(54'd0), .CASI(55'd0), .ASIGN(1'b0), .BSIGN(1'b0),
    .ACCLOAD(~load_r), .CE(1'b1), .CLK(clk), .RESET(1'b0), .DOUT(count), .CASO(caso));
  defparam alu.AREG=1'b0; defparam alu.BREG=1'b0; defparam alu.ASIGN_REG=1'b0; defparam alu.BSIGN_REG=1'b0;
  defparam alu.ACCLOAD_REG=1'b0; defparam alu.OUT_REG=1'b1; defparam alu.B_ADD_SUB=1'b0; defparam alu.C_ADD_SUB=1'b0;
  defparam alu.ALUD_MODE=0; defparam alu.ALU_RESET_MODE="SYNC";
  always @(posedge clk) begin
    value <= {value[62:0], din}; load_r <= load;
    tail <= load_r ? value[63:54] : tail + caso[54];
    out <= ^{tail, count};
  end
  assign dout = out;
endmodule
