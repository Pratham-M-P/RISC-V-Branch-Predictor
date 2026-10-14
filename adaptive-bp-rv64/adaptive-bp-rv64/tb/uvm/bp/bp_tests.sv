// -----------------------------------------------------------------------------
// Tests   (select with +UVM_TESTNAME=<name>)
//   bp_directed_test  loop / pattern / call-return (> RAS depth) / BTB-alias scenarios
//   bp_random_test    constrained-random synthetic programs (+NITEMS=, +REPS=)
//   bp_stress_test    high branch density, many stalls, deep pipeline latency
// -----------------------------------------------------------------------------
class bp_base_test extends uvm_test;
  `uvm_component_utils(bp_base_test)
  bp_env        env;
  bp_cfg        cfg;
  virtual bp_if vif;

  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  virtual function void configure(bp_cfg c);
  endfunction

  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(bp_cfg)::get(this, "", "cfg_top", cfg)) `uvm_fatal("TEST", "no cfg_top")
    if (!uvm_config_db#(virtual bp_if)::get(this, "", "vif", vif)) `uvm_fatal("TEST", "no vif")
    configure(cfg);
    uvm_config_db#(bp_cfg)::set(this, "env*", "cfg", cfg);
    uvm_config_db#(bp_cfg)::set(this, "env.agent.sqr*", "cfg", cfg);
    env = bp_env::type_id::create("env", this);
  endfunction

  task drain();
    repeat ((cfg.pipe_lat + 4) * 6 + 40) @(posedge vif.clk);
  endtask

  virtual task run_scenarios();
  endtask

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    wait (vif.rst_n === 1'b1);
    run_scenarios();
    drain();
    phase.drop_objection(this);
  endtask

  function void report_phase(uvm_phase phase);
    uvm_report_server srv = uvm_report_server::get_server();
    if (srv.get_severity_count(UVM_ERROR) + srv.get_severity_count(UVM_FATAL) == 0)
      `uvm_info("RESULT", "UVM_TEST_RESULT: PASS", UVM_NONE)
    else
      `uvm_info("RESULT", "UVM_TEST_RESULT: FAIL", UVM_NONE)
  endfunction
endclass

class bp_directed_test extends bp_base_test;
  `uvm_component_utils(bp_directed_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task run_scenarios();
    bp_directed_all_seq s = bp_directed_all_seq::type_id::create("s");
    repeat (3) s.start(env.agent.sqr);
  endtask
endclass

class bp_random_test extends bp_base_test;
  `uvm_component_utils(bp_random_test)
  int unsigned reps = 6, nitems = 0;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task run_scenarios();
    void'($value$plusargs("REPS=%d", reps));
    void'($value$plusargs("NITEMS=%d", nitems));
    repeat (reps) begin
      bp_random_seq s = bp_random_seq::type_id::create("s");
      if (nitems != 0) begin
        if (!s.randomize() with { n_items == local::nitems; }) `uvm_fatal("TEST", "randomize failed")
      end else begin
        if (!s.randomize()) `uvm_fatal("TEST", "randomize failed")
      end
      s.mix_cond_pct = $urandom_range(10, 60);
      s.start(env.agent.sqr);
    end
  endtask
endclass

class bp_stress_test extends bp_base_test;
  `uvm_component_utils(bp_stress_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void configure(bp_cfg c);
    c.pipe_lat  = 4;
    c.stall_pct = 35;
    c.code_words = 96;
  endfunction
  task run_scenarios();
    repeat (4) begin
      bp_random_seq s = bp_random_seq::type_id::create("s");
      if (!s.randomize()) `uvm_fatal("TEST", "randomize failed")
      s.mix_cond_pct = 60;
      s.start(env.agent.sqr);
    end
    begin
      bp_callret_seq c = bp_callret_seq::type_id::create("c");
      if (!c.randomize() with { depth > 9; }) `uvm_fatal("TEST", "randomize failed")
      c.start(env.agent.sqr);
    end
  endtask
endclass
