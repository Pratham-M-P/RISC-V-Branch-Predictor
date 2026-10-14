class core_monitor extends uvm_monitor;
  `uvm_component_utils(core_monitor)
  virtual core_if vif;
  uvm_analysis_port #(core_cyc_item) ap;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    ap = new("ap", this);
    if (!uvm_config_db#(virtual core_if)::get(this, "", "vif", vif)) `uvm_fatal("MON", "no vif")
  endfunction
  task run_phase(uvm_phase phase);
    forever begin
      core_cyc_item c;
      @(vif.mon_cb);
      c = core_cyc_item::type_id::create("c");
      c.rst_n = vif.mon_cb.rst_n;  c.halted = vif.mon_cb.halted;  c.illegal = vif.mon_cb.illegal;  c.stall = vif.mon_cb.stall;
      c.commit_valid = vif.mon_cb.commit_valid; c.commit_pc = vif.mon_cb.commit_pc;
      c.commit_instr = vif.mon_cb.commit_instr; c.commit_rd = vif.mon_cb.commit_rd; c.commit_data = vif.mon_cb.commit_data;
      c.res_valid = vif.mon_cb.res_valid; c.res_is_cond = vif.mon_cb.res_is_cond; c.res_is_ctrl = vif.mon_cb.res_is_ctrl;
      c.res_taken = vif.mon_cb.res_taken; c.res_pred_taken = vif.mon_cb.res_pred_taken;
      c.res_mispredict = vif.mon_cb.res_mispredict; c.res_pc = vif.mon_cb.res_pc;
      c.res_target = vif.mon_cb.res_target; c.res_pred_target = vif.mon_cb.res_pred_target;
      c.perf_cycles = vif.mon_cb.perf_cycles; c.perf_instret = vif.mon_cb.perf_instret;
      c.perf_cond_br = vif.mon_cb.perf_cond_br; c.perf_cond_mispred = vif.mon_cb.perf_cond_mispred;
      c.perf_ctrl = vif.mon_cb.perf_ctrl; c.perf_ctrl_mispred = vif.mon_cb.perf_ctrl_mispred;
      ap.write(c);
    end
  endtask
endclass
