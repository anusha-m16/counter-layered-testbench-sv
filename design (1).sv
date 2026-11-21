// DUT : 4 bit up counter with synchronous reset and enable

module counter (
  input  logic       clk,
  input  logic       rst,     // reset, active high, works on clock edge (synchronous)
  input  logic       en,      // counter counts only when this is 1
  output logic [3:0] count    // 4 bits so value is 0 to 15
);

  always @(posedge clk) begin
    if (rst)
      count <= 4'd0;                // reset has the highest priority
    else if (en)
      count <= count + 4'd1;        // add 1, after 15 it goes back to 0 (4 bit overflow)
    // if en is 0 count stays the same
  end

endmodule
