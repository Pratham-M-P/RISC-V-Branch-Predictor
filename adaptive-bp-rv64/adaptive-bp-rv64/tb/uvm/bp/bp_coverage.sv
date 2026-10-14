// -----------------------------------------------------------------------------
// bp_coverage : functional coverage of the predictor interface
// -----------------------------------------------------------------------------
class bp_coverage extends uvm_subscriber #(bp_mon_item);
  `uvm_component_utils(bp_coverage)

  bp_mon_item t_s;
  bit [2:0]   kind_s;     // 0 none 1 cond 2 jal 3 call 4 ret 5 jalr(non-ret,non-call) 6 icall

  covergroup cg_resolve;
    option.per_instance = 1;
    cp_kind: coverpoint kind_s { bins none = {0}; bins cond = {1}; bins jal = {2}; bins call = {3};
                                 bins ret = {4}; bins jalr = {5}; bins icall = {6}; }
    cp_taken: coverpoint t_s.upd.taken;
    cp_mis:   coverpoint t_s.upd.mispredict;
    cp_comp_agree: coverpoint (t_s.upd.meta.bim_taken == t_s.upd.meta.gsh_taken) { bins agree = {1}; bins differ = {0}; }
    cp_bim_ok: coverpoint (t_s.upd.meta.bim_taken == t_s.upd.taken) { bins ok = {1}; bins wrong = {0}; }
    cp_gsh_ok: coverpoint (t_s.upd.meta.gsh_taken == t_s.upd.taken) { bins ok = {1}; bins wrong = {0}; }
    x_kind_taken_mis: cross cp_kind, cp_taken, cp_mis {
      ignore_bins jumps_not_taken = binsof(cp_kind) intersect {2, 3, 4, 5, 6} && binsof(cp_taken) intersect {0};
      ignore_bins none_taken      = binsof(cp_kind) intersect {0} && binsof(cp_taken) intersect {1};
    }
    // adaptive behaviour: components disagree, which one was right, outcome
    x_tournament: cross cp_comp_agree, cp_bim_ok, cp_gsh_ok {
      ignore_bins impossible = binsof(cp_comp_agree.agree) && binsof(cp_bim_ok.ok) && binsof(cp_gsh_ok.wrong);
      ignore_bins impossible2 = binsof(cp_comp_agree.agree) && binsof(cp_bim_ok.wrong) && binsof(cp_gsh_ok.ok);
      ignore_bins impossible3 = binsof(cp_comp_agree.differ) && binsof(cp_bim_ok.ok) && binsof(cp_gsh_ok.ok);
      ignore_bins impossible4 = binsof(cp_comp_agree.differ) && binsof(cp_bim_ok.wrong) && binsof(cp_gsh_ok.wrong);
    }
    cp_ras_depth: coverpoint t_s.upd.meta.ras_ptr { bins low[] = {[0:3]}; bins mid[] = {[4:7]}; bins high = {[8:15]}; }
  endgroup

  covergroup cg_fetch;
    option.per_instance = 1;
    cp_adv:  coverpoint t_s.adv;
    cp_pred: coverpoint t_s.pred_taken;
    cp_upd:  coverpoint t_s.upd.valid;
    cp_rec:  coverpoint (t_s.upd.valid && t_s.upd.mispredict);
    x_fetch: cross cp_adv, cp_pred, cp_upd;
    x_recover_fetch: cross cp_rec, cp_adv;                  // recovery concurrent with fetch advance
    cp_ghr: coverpoint t_s.pred_meta.ghr[3:0];               // history values seen
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cg_resolve = new();
    cg_fetch   = new();
  endfunction

  function void write(bp_mon_item t);
    if (!t.rst_n) return;
    t_s = t;
    cg_fetch.sample();
    if (t.upd.valid) begin
      if      (t.upd.is_cond)                      kind_s = 1;
      else if (t.upd.is_jal && !t.upd.is_call)     kind_s = 2;
      else if (t.upd.is_jal &&  t.upd.is_call)     kind_s = 3;
      else if (t.upd.is_ret)                       kind_s = 4;
      else if (t.upd.is_jalr && !t.upd.is_call)    kind_s = 5;
      else if (t.upd.is_jalr &&  t.upd.is_call)    kind_s = 6;
      else                                         kind_s = 0;
      cg_resolve.sample();
    end
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("COV", $sformatf("resolve coverage=%.1f%%  fetch coverage=%.1f%%",
              cg_resolve.get_inst_coverage(), cg_fetch.get_inst_coverage()), UVM_LOW)
  endfunction
endclass
