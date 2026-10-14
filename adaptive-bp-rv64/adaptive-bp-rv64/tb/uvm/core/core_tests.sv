// -----------------------------------------------------------------------------
// core_prog_test : runs the program given by +HEX=<imem image> (loaded by rv64_imem)
//                  to completion and lets the scoreboard compare against +GOLDEN=<ISS trace>.
//   +MAXCYCLES=<n>  watchdog (default 2,000,000)
// The program set is produced by python/uvm_flow.py: directed asm tests, the benchmarks and
// constrained-random programs from python/rvtools/progen.py.
// -----------------------------------------------------------------------------
class core_prog_test extends uvm_test;
  `uvm_component_utils(core_prog_test)
  core_env        env;
  virtual core_if vif;
  int unsigned    max_cycles = 2000000;

  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual core_if)::get(this, "", "vif", vif)) `uvm_fatal("TEST", "no vif")
    env = core_env::type_id::create("env", this);
    void'($value$plusargs("MAXCYCLES=%d", max_cycles));
  endfunction

  task run_phase(uvm_phase phase);
    int unsigned cyc = 0;
    phase.raise_objection(this);
    wait (vif.rst_n === 1'b1);
    while (!vif.halted && cyc < max_cycles) begin
      @(posedge vif.clk);
      cyc++;
    end
    repeat (8) @(posedge vif.clk);       // let the monitor see the final counter values
    if (!vif.halted) `uvm_error("TEST", $sformatf("watchdog expired after %0d cycles", cyc))
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
