// Generated RTL regression: independent input stalls and output backpressure.
`timescale 1ns/1ps
module tb_deflate;
  reg clk=0, reset=1;
  always #5 clk=~clk;
  reg [2047:0] vector_name;
  reg [7:0] rom[0:1048575], expected[0:1048575];
  integer rom_len, exp_len, reject, input_seed, output_seed;
  integer feed_index=0, out_index=0, cycle=0;
  reg in_valid=0, in_end=0, out_ready=0;
  reg [7:0] in_byte=0;
  wire in_ready, out_valid, done, bad;
  wire [7:0] out_byte;
  reg held=0;
  reg [7:0] held_byte;
  deflate_inflate dut(.clk(clk),.reset(reset),.enable(1'b1),
    .in_valid(in_valid),.in_byte(in_byte),.in_end(in_end),.out_ready(out_ready),
    .in_ready(in_ready),.out_valid(out_valid),.out_byte(out_byte),.done(done),.bad(bad));
  function allowed;
    input integer seed, tick;
    begin allowed = seed==0 || (((tick*17+seed*13)%23 >= 8) && ((tick+seed)%101 >= 11)); end
  endfunction
  // Drive at the opposite edge; once offered, retain input until accepted.
  always @(negedge clk) begin
    if (!reset) begin
      if (!in_valid) begin
        in_valid = feed_index < rom_len && allowed(input_seed,cycle);
        in_byte = feed_index < rom_len ? rom[feed_index] : 0;
      end
      in_end = feed_index == rom_len;
      out_ready = allowed(output_seed,cycle);
    end
  end
  always @(posedge clk) begin
    if (!reset) begin
      cycle = cycle+1;
      if (held && (out_valid !== 1'b1 || out_byte !== held_byte))
        $fatal(1,"output changed under backpressure");
      held = out_valid && !out_ready;
      held_byte = out_byte;
      if (in_valid && in_ready) begin feed_index=feed_index+1; in_valid<=0; end
      if (out_valid && out_ready) begin
        if (out_index >= exp_len || out_byte !== expected[out_index])
          $fatal(1,"byte %0d got %02x expected %02x",out_index,out_byte,expected[out_index]);
        out_index=out_index+1;
      end
      if (done || bad) begin
        if (bad !== (reject != 0) || done !== (reject == 0) || out_index != exp_len)
          $fatal(1,"terminal mismatch done=%b bad=%b bytes=%0d expected=%0d",done,bad,out_index,exp_len);
        $display("PASS %0s input=%0d output=%0d cycles=%0d",vector_name,input_seed,output_seed,cycle);
        $finish;
      end
      if (cycle > 3000000) $fatal(1,"timeout fed=%0d/%0d out=%0d ready=%b valid=%b eof=%b",feed_index,rom_len,out_index,in_ready,in_valid,in_end);
    end
  end
  initial begin
    if (!$value$plusargs("VECTOR=%s",vector_name) ||
        !$value$plusargs("INPUT_LEN=%d",rom_len) || !$value$plusargs("OUTPUT_LEN=%d",exp_len) ||
        !$value$plusargs("REJECT=%d",reject) || !$value$plusargs("INPUT_SEED=%d",input_seed) ||
        !$value$plusargs("OUTPUT_SEED=%d",output_seed)) $fatal(1,"missing arguments");
    if (rom_len>0) $readmemh({vector_name,".deflate.hex"},rom,0,rom_len-1);
    if (exp_len>0) $readmemh({vector_name,".expected.hex"},expected,0,exp_len-1);
    repeat(4) @(negedge clk);
    reset=0;
  end
endmodule
