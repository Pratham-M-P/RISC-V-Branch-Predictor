// tb_core_uvm_top : whole-SoC UVM testbench (core + predictor + memories)
module tb_core_uvm_top;
  import uvm_pkg::*;
  import core_uvm_pkg::*;
  `include "uvm_macros.svh"

  parameter int unsigned PREDICTOR_TYPE = 3;
  parameter int unsigned BIM_IDX_W = 10, GSH_IDX_W = 10, CHO_IDX_W = 10, BTB_IDX_W = 6, RAS_DEPTH = 8;

  logic clk = 1'b0;
  always #5 clk = ~clk;

  core_if vif (.clk(clk));

  logic [63:0] gpio;

  rv64_soc #(.PREDICTOR_TYPE(PREDICTOR_TYPE), .BIM_IDX_W(BIM_IDX_W), .GSH_IDX_W(GSH_IDX_W),
             .CHO_IDX_W(CHO_IDX_W), .BTB_IDX_W(BTB_IDX_W), .RAS_DEPTH(RAS_DEPTH)) dut (
    .clk, .rst_n(vif.rst_n), .gpio_out(gpio), .halted_o(vif.halted), .illegal_o(vif.illegal),
    .commit_valid(vif.commit_valid), .commit_pc(vif.commit_pc), .commit_instr(vif.commit_instr),
    .commit_rd(vif.commit_rd), .commit_data(vif.commit_data),
    .res_valid(vif.res_valid), .res_pc(vif.res_pc), .res_is_cond(vif.res_is_cond),
    .res_is_ctrl(vif.res_is_ctrl), .res_taken(vif.res_taken), .res_target(vif.res_target),
    .res_pred_taken(vif.res_pred_taken), .res_pred_target(vif.res_pred_target),
    .res_mispredict(vif.res_mispredict), .stall_o(vif.stall),
    .perf_cycles(vif.perf_cycles), .perf_instret(vif.perf_instret), .perf_cond_br(vif.perf_cond_br),
    .perf_cond_mispred(vif.perf_cond_mispred), .perf_ctrl(vif.perf_ctrl), .perf_ctrl_mispred(vif.perf_ctrl_mispred));

  initial begin
    vif.rst_n = 1'b0;
    repeat (5) @(posedge clk);
    #1 vif.rst_n = 1'b1;
  end

  initial begin
    uvm_config_db#(virtual core_if)::set(null, "*", "vif", vif);
    run_test("core_prog_test");
  end
endmodule
