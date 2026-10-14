// -----------------------------------------------------------------------------
// tb_bp_uvm_top : top module of the predictor-level UVM testbench
// -----------------------------------------------------------------------------
module tb_bp_uvm_top;
  import uvm_pkg::*;
  import bp_pkg::*;
  import bp_uvm_pkg::*;
  `include "uvm_macros.svh"

  parameter int unsigned PREDICTOR_TYPE = BP_TOURNAMENT;
  parameter int unsigned BIM_IDX_W = 10, GSH_IDX_W = 10, CHO_IDX_W = 10;
  parameter int unsigned BTB_IDX_W = 6, BTB_TAG_W = 16, RAS_DEPTH = 8;

  logic clk = 1'b0;
  always #5 clk = ~clk;

  bp_if vif (.clk(clk), .ptype(PREDICTOR_TYPE));

  branch_predictor #(
    .PREDICTOR_TYPE(PREDICTOR_TYPE), .BIM_IDX_W(BIM_IDX_W), .GSH_IDX_W(GSH_IDX_W),
    .CHO_IDX_W(CHO_IDX_W), .BTB_IDX_W(BTB_IDX_W), .BTB_TAG_W(BTB_TAG_W), .RAS_DEPTH(RAS_DEPTH)
  ) dut (
    .clk           (clk),
    .rst_n         (vif.rst_n),
    .pc_i          (vif.pc),
    .fetch_adv_i   (vif.adv),
    .pred_taken_o  (vif.pred_taken),
    .pred_target_o (vif.pred_target),
    .pred_meta_o   (vif.pred_meta),
    .upd_i         (vif.upd)
  );

  initial begin
    bp_cfg cfg;
    cfg = new("cfg_top");
    cfg.ptype = PREDICTOR_TYPE; cfg.bim_w = BIM_IDX_W; cfg.gsh_w = GSH_IDX_W; cfg.cho_w = CHO_IDX_W;
    cfg.btb_w = BTB_IDX_W; cfg.tag_w = BTB_TAG_W; cfg.ras_d = RAS_DEPTH;
    uvm_config_db#(virtual bp_if)::set(null, "*", "vif", vif);
    uvm_config_db#(bp_cfg)::set(null, "*", "cfg_top", cfg);
    run_test();
  end
endmodule
