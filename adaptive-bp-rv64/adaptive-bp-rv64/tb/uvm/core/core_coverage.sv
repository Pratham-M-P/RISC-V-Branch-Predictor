// core_coverage : instruction-mix, branch behaviour and hazard/stall functional coverage
class core_coverage extends uvm_subscriber #(core_cyc_item);
  `uvm_component_utils(core_coverage)
  core_cyc_item t_s;
  bit [3:0]     cls_s;     // instruction class
  bit [1:0]     brk_s;     // 0 conditional, 1 unconditional jump

  covergroup cg_instr;
    option.per_instance = 1;
    cp_class: coverpoint cls_s { bins alu_r = {0}; bins alu_i = {1}; bins load = {2}; bins store = {3};
                                 bins branch = {4}; bins jal = {5}; bins jalr = {6}; bins lui_auipc = {7};
                                 bins alu_w = {8}; bins system = {9}; bins fence = {10}; }
    cp_f3: coverpoint t_s.commit_instr[14:12] iff (cls_s inside {2, 3, 4}) { bins f[] = {[0:7]}; }
    x_class_f3: cross cp_class, cp_f3 {
      ignore_bins nonmem = !binsof(cp_class) intersect {2, 3, 4};
    }
    cp_rd_zero: coverpoint (t_s.commit_rd == 0) iff (cls_s inside {0, 1, 8});
  endgroup

  covergroup cg_branch;
    option.per_instance = 1;
    cp_type:  coverpoint brk_s { bins cond = {0}; bins jump = {1}; }
    cp_pred:  coverpoint t_s.res_pred_taken;
    cp_act:   coverpoint t_s.res_taken;
    cp_back:  coverpoint (t_s.res_target < t_s.res_pc) iff (t_s.res_is_cond) { bins fwd = {0}; bins back = {1}; }
    x_branch: cross cp_type, cp_pred, cp_act {
      ignore_bins jmp_nt = binsof(cp_type) intersect {1} && binsof(cp_act) intersect {0};
    }
    x_back_mis: cross cp_back, cp_act, cp_pred;
  endgroup

  covergroup cg_pipe;
    option.per_instance = 1;
    cp_stall: coverpoint t_s.stall;
    cp_mis:   coverpoint t_s.res_mispredict;
    x_stall_mis: cross cp_stall, cp_mis;
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cg_instr = new(); cg_branch = new(); cg_pipe = new();
  endfunction

  function void write(core_cyc_item t);
    if (!t.rst_n) return;
    t_s = t;
    cg_pipe.sample();
    if (t.commit_valid) begin
      case (t.commit_instr[6:0])
        7'b0110011: cls_s = 0;  7'b0010011: cls_s = 1;  7'b0000011: cls_s = 2;  7'b0100011: cls_s = 3;
        7'b1100011: cls_s = 4;  7'b1101111: cls_s = 5;  7'b1100111: cls_s = 6;
        7'b0110111, 7'b0010111: cls_s = 7;
        7'b0111011, 7'b0011011: cls_s = 8;
        7'b1110011: cls_s = 9;  7'b0001111: cls_s = 10;
        default: cls_s = 11;
      endcase
      if (cls_s != 11) cg_instr.sample();
    end
    if (t.res_valid) begin
      brk_s = t.res_is_cond ? 2'd0 : 2'd1;
      cg_branch.sample();
    end
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("COV", $sformatf("instr=%.1f%% branch=%.1f%% pipe=%.1f%%", cg_instr.get_inst_coverage(),
              cg_branch.get_inst_coverage(), cg_pipe.get_inst_coverage()), UVM_LOW)
  endfunction
endclass
