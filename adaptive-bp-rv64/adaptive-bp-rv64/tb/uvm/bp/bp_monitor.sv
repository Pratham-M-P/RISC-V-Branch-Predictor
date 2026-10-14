// bp_monitor : samples every clock cycle (pre-edge values) and publishes it
class bp_monitor extends uvm_monitor;
  `uvm_component_utils(bp_monitor)
  virtual bp_if vif;
  uvm_analysis_port #(bp_mon_item) ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    ap = new("ap", this);
    if (!uvm_config_db#(virtual bp_if)::get(this, "", "vif", vif)) `uvm_fatal("MON", "no vif")
  endfunction

  task run_phase(uvm_phase phase);
    forever begin
      bp_mon_item it;
      @(vif.mon_cb);
      it = bp_mon_item::type_id::create("it");
      it.rst_n       = vif.mon_cb.rst_n;
      it.pc          = vif.mon_cb.pc;
      it.adv         = vif.mon_cb.adv;
      it.upd         = vif.mon_cb.upd;
      it.pred_taken  = vif.mon_cb.pred_taken;
      it.pred_target = vif.mon_cb.pred_target;
      it.pred_meta   = vif.mon_cb.pred_meta;
      ap.write(it);
    end
  endtask
endclass
