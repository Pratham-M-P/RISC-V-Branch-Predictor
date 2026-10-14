// -----------------------------------------------------------------------------
// rv64_dmem : data RAM, 64-bit words, byte enables, asynchronous read.
//   INIT_FILE : $readmemh image, one 64-bit word per line
//   +DHEX=<f> : simulation-only override
// -----------------------------------------------------------------------------
module rv64_dmem #(
  parameter int unsigned AW        = 11,        // log2(64-bit words)
  parameter string       INIT_FILE = ""
) (
  input  logic        clk,
  input  logic [63:0] addr,
  input  logic        we,
  input  logic [7:0]  be,
  input  logic [63:0] wdata,
  output logic [63:0] rdata
);
  logic [63:0] mem [0:(1<<AW)-1];

  initial begin
    for (int i = 0; i < (1 << AW); i++) mem[i] = '0;
    if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
`ifndef SYNTHESIS
    begin
      string hexf;
      if ($value$plusargs("DHEX=%s", hexf)) $readmemh(hexf, mem);
    end
`endif
  end

  wire [AW-1:0] widx = addr[AW+2:3];

  assign rdata = mem[widx];

  always_ff @(posedge clk) begin
    if (we) begin
      for (int b = 0; b < 8; b++)
        if (be[b]) mem[widx][8*b +: 8] <= wdata[8*b +: 8];
    end
  end
endmodule
