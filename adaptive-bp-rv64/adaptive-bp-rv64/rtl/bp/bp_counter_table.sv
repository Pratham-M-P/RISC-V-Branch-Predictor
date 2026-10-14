// -----------------------------------------------------------------------------
// bp_counter_table : table of 2-bit saturating counters
//   * two asynchronous read ports (predict @ fetch, read-modify-write @ resolve)
//   * one synchronous write port
//   * contents come from an initial block (maps to LUT-RAM init on Xilinx)
// -----------------------------------------------------------------------------
module bp_counter_table #(
  parameter int unsigned IDX_W = 10,
  parameter logic [1:0]  INIT  = 2'b01        // weakly not-taken / weakly "pick bimodal"
) (
  input  logic             clk,
  // prediction port
  input  logic [IDX_W-1:0] rd_idx,
  output logic [1:0]       rd_ctr,
  // update port (read old value, write new value)
  input  logic [IDX_W-1:0] upd_idx,
  output logic [1:0]       upd_ctr,
  input  logic             wr_en,
  input  logic [1:0]       wr_val
);
  logic [1:0] mem [0:(1<<IDX_W)-1];

  initial begin
    for (int i = 0; i < (1 << IDX_W); i++) mem[i] = INIT;
  end

  assign rd_ctr  = mem[rd_idx];
  assign upd_ctr = mem[upd_idx];

  always_ff @(posedge clk) begin
    if (wr_en) mem[upd_idx] <= wr_val;
  end
endmodule
