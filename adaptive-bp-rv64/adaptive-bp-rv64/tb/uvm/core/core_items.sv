// One clock cycle worth of probe values
class core_cyc_item extends uvm_object;
  bit          rst_n, halted, illegal, stall;
  bit          commit_valid;
  bit [63:0]   commit_pc, commit_data;
  bit [31:0]   commit_instr;
  bit [4:0]    commit_rd;
  bit          res_valid, res_is_cond, res_is_ctrl, res_taken, res_pred_taken, res_mispredict;
  bit [63:0]   res_pc, res_target, res_pred_target;
  bit [63:0]   perf_cycles, perf_instret, perf_cond_br, perf_cond_mispred, perf_ctrl, perf_ctrl_mispred;
  `uvm_object_utils(core_cyc_item)
  function new(string name = "core_cyc_item"); super.new(name); endfunction
endclass

// Golden commit record (from the Python ISS trace)
class core_gold_rec;
  bit [63:0] pc, data;
  bit [31:0] instr;
  bit [4:0]  rd;
  function bit is_ctrl();
    return instr[6:0] inside {7'b1100011, 7'b1101111, 7'b1100111};
  endfunction
  function bit is_cond();
    return instr[6:0] == 7'b1100011;
  endfunction
endclass
