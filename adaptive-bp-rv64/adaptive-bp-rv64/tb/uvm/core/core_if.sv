// -----------------------------------------------------------------------------
// core_if : probe interface on rv64_soc (commit stream, branch resolution, status)
//           + pipeline-behaviour assertions and cover properties
// -----------------------------------------------------------------------------
interface core_if (input logic clk);
  logic        rst_n = 1'b0;
  logic        halted, illegal, stall;

  logic        commit_valid;
  logic [63:0] commit_pc;
  logic [31:0] commit_instr;
  logic [4:0]  commit_rd;
  logic [63:0] commit_data;

  logic        res_valid, res_is_cond, res_is_ctrl, res_taken, res_pred_taken, res_mispredict;
  logic [63:0] res_pc, res_target, res_pred_target;

  logic [63:0] perf_cycles, perf_instret, perf_cond_br, perf_cond_mispred, perf_ctrl, perf_ctrl_mispred;

  clocking mon_cb @(posedge clk);
    default input #1step;
    input rst_n, halted, illegal, stall, commit_valid, commit_pc, commit_instr, commit_rd, commit_data,
          res_valid, res_is_cond, res_is_ctrl, res_taken, res_pred_taken, res_mispredict,
          res_pc, res_target, res_pred_target,
          perf_cycles, perf_instret, perf_cond_br, perf_cond_mispred, perf_ctrl, perf_ctrl_mispred;
  endclocking

  // ---- assertions ----------------------------------------------------------------------
  // P1: the flag the core reports must equal "fetched next-PC != real next-PC"
  a_mispredict_def: assert property (@(posedge clk) disable iff (!rst_n)
      res_valid |-> (res_mispredict ==
        ((res_pred_taken ? res_pred_target : res_pc + 64'd4) != (res_taken ? res_target : res_pc + 64'd4))))
    else $error("[core_if] mispredict flag inconsistent with predicted/actual next-PC");

  // P2: a mispredict squashes the next two EX slots (2-cycle penalty, no back-to-back flush)
  a_mispredict_penalty: assert property (@(posedge clk) disable iff (!rst_n)
      res_mispredict |=> !res_mispredict ##1 !res_mispredict)
    else $error("[core_if] instruction reached EX during the mispredict shadow");

  // P3: unconditional jumps are always resolved taken
  a_jump_taken: assert property (@(posedge clk) disable iff (!rst_n)
      (res_valid && !res_is_cond) |-> res_taken)
    else $error("[core_if] jal/jalr resolved not-taken");

  // P4: nothing commits after the machine has halted
  a_no_commit_after_halt: assert property (@(posedge clk) disable iff (!rst_n)
      $past(halted) |-> !commit_valid)
    else $error("[core_if] commit after halt");

  // P5: commit stream is well formed
  a_commit_known: assert property (@(posedge clk) disable iff (!rst_n)
      commit_valid |-> !$isunknown({commit_pc, commit_instr, commit_rd, commit_data}))
    else $error("[core_if] X on commit bus");
  a_commit_aligned: assert property (@(posedge clk) disable iff (!rst_n)
      commit_valid |-> (commit_pc[1:0] == 2'b00))
    else $error("[core_if] unaligned commit PC");
  a_x0_never_written: assert property (@(posedge clk) disable iff (!rst_n)
      (commit_valid && commit_rd == 5'd0) |-> (commit_data == 64'd0))
    else $error("[core_if] data reported for x0");

  // P6: performance counters are monotonic
  a_cycles_monotonic: assert property (@(posedge clk) disable iff (!rst_n)
      perf_cycles >= $past(perf_cycles))
    else $error("[core_if] cycle counter went backwards");
  a_mp_le_br: assert property (@(posedge clk) disable iff (!rst_n)
      perf_cond_mispred <= perf_cond_br)
    else $error("[core_if] more mispredicts than branches");

  // ---- cover properties -------------------------------------------------------------------
  c_load_use_stall:   cover property (@(posedge clk) disable iff (!rst_n) stall);
  c_mispredict:       cover property (@(posedge clk) disable iff (!rst_n) res_mispredict);
  c_mis_after_stall:  cover property (@(posedge clk) disable iff (!rst_n) stall ##1 !stall ##[1:6] res_mispredict);
  c_two_mis_close:    cover property (@(posedge clk) disable iff (!rst_n) res_mispredict ##[3:5] res_mispredict);
endinterface
