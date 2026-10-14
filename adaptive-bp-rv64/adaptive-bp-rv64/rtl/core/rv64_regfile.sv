// -----------------------------------------------------------------------------
// rv64_regfile : 32 x 64-bit register file, 2 read ports, 1 write port,
//                write-through bypass (a same-cycle WB write is visible to ID).
// -----------------------------------------------------------------------------
module rv64_regfile
  import rv64_pkg::*;
(
  input  logic            clk,
  input  logic [4:0]      rs1_addr,
  input  logic [4:0]      rs2_addr,
  output logic [XLEN-1:0] rs1_data,
  output logic [XLEN-1:0] rs2_data,
  input  logic            we,
  input  logic [4:0]      wr_addr,
  input  logic [XLEN-1:0] wr_data
);
  logic [XLEN-1:0] regs [0:31];

  initial begin
    for (int i = 0; i < 32; i++) regs[i] = '0;
  end

  always_ff @(posedge clk) begin
    if (we && wr_addr != 5'd0) regs[wr_addr] <= wr_data;
  end

  always_comb begin
    if (rs1_addr == 5'd0)                       rs1_data = '0;
    else if (we && wr_addr == rs1_addr)         rs1_data = wr_data;
    else                                        rs1_data = regs[rs1_addr];

    if (rs2_addr == 5'd0)                       rs2_data = '0;
    else if (we && wr_addr == rs2_addr)         rs2_data = wr_data;
    else                                        rs2_data = regs[rs2_addr];
  end
endmodule
