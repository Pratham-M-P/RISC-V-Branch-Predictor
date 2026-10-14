// -----------------------------------------------------------------------------
// bp_scoreboard : compares the DUT against bp_ref_model *every cycle*
//   * predicted direction, target (when taken) and the whole metadata word
//   * the model is advanced with exactly the stimulus the DUT saw (incl. recovery)
// -----------------------------------------------------------------------------
class bp_scoreboard extends uvm_subscriber #(bp_mon_item);
  `uvm_component_utils(bp_scoreboard)

  bp_cfg        cfg;
  bp_ref_model  model;
  longint unsigned n_cycles, n_checked, n_pred_taken, n_mis, n_resolved, n_err;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(bp_cfg)::get(this, "", "cfg", cfg)) `uvm_fatal("SB", "no cfg")
    model = new(cfg.ptype, cfg.bim_w, cfg.gsh_w, cfg.cho_w, cfg.btb_w, cfg.tag_w, cfg.ras_d);
  endfunction

  function void write(bp_mon_item t);
    n_cycles++;
    if (!t.rst_n) begin
      model.reset();
      return;
    end
    begin
      bit e_taken; bit [63:0] e_target; bp_pkg::bp_meta_t e_meta;
      model.predict(t.pc, e_taken, e_target, e_meta);
      n_checked++;
      if (e_taken !== t.pred_taken) begin
        n_err++;
        `uvm_error("SB_DIR", $sformatf("pc=%h expected taken=%0b got %0b", t.pc, e_taken, t.pred_taken))
      end else if (e_taken && e_target !== t.pred_target) begin
        n_err++;
        `uvm_error("SB_TGT", $sformatf("pc=%h expected target=%h got %h", t.pc, e_target, t.pred_target))
      end
      if (e_meta !== t.pred_meta) begin
        n_err++;
        `uvm_error("SB_META", $sformatf("pc=%h expected meta=%h got %h", t.pc, e_meta, t.pred_meta))
      end
      n_pred_taken += t.pred_taken;
      if (t.upd.valid) begin
        n_resolved++;
        n_mis += t.upd.mispredict;
      end
      model.step(t.pc, t.adv, t.upd);
    end
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("SB", $sformatf("cycles=%0d checked=%0d predicted-taken=%0d resolved=%0d mispredicts=%0d errors=%0d",
              n_cycles, n_checked, n_pred_taken, n_resolved, n_mis, n_err), UVM_LOW)
    if (n_checked == 0) `uvm_error("SB", "scoreboard checked nothing")
  endfunction
endclass
