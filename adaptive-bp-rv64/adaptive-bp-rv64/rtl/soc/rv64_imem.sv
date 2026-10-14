// -----------------------------------------------------------------------------
// rv64_imem : instruction ROM/RAM, 32-bit words, asynchronous read.
//   INIT_FILE : $readmemh image, one 32-bit word per line (synthesis + simulation)
//   +HEX=<f>  : simulation-only override (hidden from synthesis)
//   Unused locations hold ECALL so a runaway PC halts the machine.
// -----------------------------------------------------------------------------
module rv64_imem #(
  parameter int unsigned AW        = 12,        // log2(words)
  parameter string       INIT_FILE = ""
) (
  input  logic [63:0] addr,
  output logic [31:0] rdata
);
  logic [31:0] mem [0:(1<<AW)-1];

  initial begin
    for (int i = 0; i < (1 << AW); i++) mem[i] = 32'h0000_0073;
    if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
`ifndef SYNTHESIS
    begin
      string hexf;
      if ($value$plusargs("HEX=%s", hexf)) $readmemh(hexf, mem);
    end
`endif
  end

  assign rdata = mem[addr[AW+1:2]];
endmodule
