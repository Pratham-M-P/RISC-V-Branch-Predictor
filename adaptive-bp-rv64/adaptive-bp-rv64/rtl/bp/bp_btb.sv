// -----------------------------------------------------------------------------
// bp_btb : direct-mapped branch target buffer
//   Allocation policy: only *taken* control-flow instructions are installed.
//   A lookup hit therefore means "this PC has been seen to redirect fetch".
// -----------------------------------------------------------------------------
module bp_btb
  import bp_pkg::*;
#(
  parameter int unsigned IDX_W = 6,
  parameter int unsigned TAG_W = 16
) (
  input  logic              clk,
  // lookup (combinational)
  input  logic [XLEN-1:0]   lookup_pc,
  output logic              hit,
  output br_type_e          btype,
  output logic [XLEN-1:0]   target,
  // write: install (wr_valid=1) or invalidate (wr_valid=0) the entry of wr_pc
  input  logic              wr_en,
  input  logic              wr_valid,
  input  logic [XLEN-1:0]   wr_pc,
  input  br_type_e          wr_type,
  input  logic [XLEN-1:0]   wr_target
);
  localparam int unsigned DEPTH = 1 << IDX_W;

  logic              v_q   [0:DEPTH-1];
  logic [TAG_W-1:0]  tag_q [0:DEPTH-1];
  br_type_e          typ_q [0:DEPTH-1];
  logic [XLEN-1:0]   tgt_q [0:DEPTH-1];

  initial begin
    for (int i = 0; i < DEPTH; i++) begin
      v_q[i] = 1'b0; tag_q[i] = '0; typ_q[i] = BR_COND; tgt_q[i] = '0;
    end
  end

  wire [IDX_W-1:0] l_idx = lookup_pc[2 +: IDX_W];
  wire [TAG_W-1:0] l_tag = lookup_pc[2+IDX_W +: TAG_W];
  wire [IDX_W-1:0] w_idx = wr_pc[2 +: IDX_W];
  wire [TAG_W-1:0] w_tag = wr_pc[2+IDX_W +: TAG_W];

  assign hit    = v_q[l_idx] && (tag_q[l_idx] == l_tag);
  assign btype  = typ_q[l_idx];
  assign target = tgt_q[l_idx];

  always_ff @(posedge clk) begin
    if (wr_en) begin
      v_q[w_idx] <= wr_valid;
      if (wr_valid) begin
        tag_q[w_idx] <= w_tag;
        typ_q[w_idx] <= wr_type;
        tgt_q[w_idx] <= wr_target;
      end
    end
  end
endmodule
