// -----------------------------------------------------------------------------
// bp_driver : turns the correct-path instruction stream into pipeline-like traffic
//
//   cycle n   : drive fetch PC (+ adv); the predictor answers combinationally
//   cycle n+L : drive the resolution bundle of that instruction, using the metadata the
//               DUT returned at fetch time (exactly what the real pipeline does)
//   if the prediction disagreed with the real next-PC the driver keeps fetching
//   *wrong-path* PCs (speculative state gets polluted) until the branch resolves,
//   then the in-flight window is flushed -> this exercises GHR / RAS recovery.
// -----------------------------------------------------------------------------
class bp_inflight;
  bp_item           it;
  bit               pred_taken;
  bit [63:0]        pred_target;
  bp_pkg::bp_meta_t meta;
  int unsigned      age;
endclass

class bp_driver extends uvm_driver #(bp_item);
  `uvm_component_utils(bp_driver)

  virtual bp_if vif;
  bp_cfg        cfg;
  bp_inflight   q[$];
  int unsigned  n_fetch, n_resolve, n_mispredict, n_wrong_path;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual bp_if)::get(this, "", "vif", vif)) `uvm_fatal("DRV", "no vif")
    if (!uvm_config_db#(bp_cfg)::get(this, "", "cfg", cfg))        `uvm_fatal("DRV", "no cfg")
  endfunction

  task reset_dut();
    vif.drv_cb.rst_n <= 1'b0;
    vif.drv_cb.pc    <= '0;
    vif.drv_cb.adv   <= 1'b0;
    vif.drv_cb.upd   <= '0;
    repeat (4) @(vif.drv_cb);
    vif.drv_cb.rst_n <= 1'b1;
    @(vif.drv_cb);
  endtask

  function bit [63:0] wrong_pc();
    return cfg.code_base + 4 * $urandom_range(cfg.code_words - 1);
  endfunction

  function bp_pkg::bp_update_t build_update(bp_inflight e);
    bp_pkg::bp_update_t u = '0;
    bit [63:0] pred_next = e.pred_taken ? e.pred_target : e.it.pc + 4;
    u.valid      = 1'b1;
    u.pc         = e.it.pc;
    u.is_cond    = (e.it.kind == K_COND);
    u.is_jal     = (e.it.kind inside {K_JAL, K_CALL});
    u.is_jalr    = (e.it.kind inside {K_RET, K_JALR, K_ICALL});
    u.is_call    = (e.it.kind inside {K_CALL, K_ICALL});
    u.is_ret     = (e.it.kind == K_RET);
    u.taken      = e.it.taken;
    u.target     = e.it.target;
    u.mispredict = (pred_next != e.it.actual_next());
    u.meta       = e.meta;
    return u;
  endfunction

  task run_phase(uvm_phase phase);
    bp_item      nxt = null;
    bit          wrong_mode = 0, have_wpc = 0;
    bit [63:0]   wpc = '0, last_pc = cfg.code_base;
    reset_dut();
    forever begin
      bit [63:0]          fpc;
      bit                 fetch_correct = 0, adv;
      bp_pkg::bp_update_t u = '0;

      // ---- choose what to fetch ----------------------------------------------------
      if (wrong_mode) begin
        if (!have_wpc) begin wpc = wrong_pc(); have_wpc = 1; end
        fpc = wpc;
      end else begin
        if (nxt == null) begin
          seq_item_port.try_next_item(nxt);
          if (nxt != null) seq_item_port.item_done();
        end
        if (nxt != null) begin fpc = nxt.pc; fetch_correct = 1; end
        else             fpc = last_pc;
      end
      adv = (fetch_correct || wrong_mode) && ($urandom_range(99) >= cfg.stall_pct);

      // ---- resolve the oldest in-flight instruction once it is old enough ------------
      if (q.size() > 0 && q[0].age >= cfg.pipe_lat) u = build_update(q[0]);

      vif.drv_cb.pc  <= fpc;
      vif.drv_cb.adv <= adv;
      vif.drv_cb.upd <= u;
      @(vif.drv_cb);                         // clock edge: DUT consumed the cycle, outputs sampled
      last_pc = fpc;

      if (u.valid) begin
        n_resolve++;
        if (u.mispredict) begin
          n_mispredict++;
          q.delete();
          wrong_mode = 0; have_wpc = 0;
        end else begin
          void'(q.pop_front());
        end
      end
      foreach (q[i]) q[i].age++;

      if (adv) begin
        if (fetch_correct) begin
          bp_inflight e = new();
          e.it = nxt; e.age = 0;
          e.pred_taken  = vif.drv_cb.pred_taken;      // sampled just before the edge => for fpc
          e.pred_target = vif.drv_cb.pred_target;
          e.meta        = vif.drv_cb.pred_meta;
          q.push_back(e);
          n_fetch++;
          if ((e.pred_taken ? e.pred_target : nxt.pc + 4) != nxt.actual_next()) wrong_mode = 1;
          nxt = null;
        end else if (wrong_mode) begin
          have_wpc = 0;
          n_wrong_path++;
        end
      end
    end
  endtask

  function void report_phase(uvm_phase phase);
    `uvm_info("DRV", $sformatf("fetched=%0d resolved=%0d mispredicts=%0d wrong-path fetches=%0d",
              n_fetch, n_resolve, n_mispredict, n_wrong_path), UVM_LOW)
  endfunction
endclass
