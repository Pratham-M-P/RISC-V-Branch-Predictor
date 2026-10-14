class core_env extends uvm_env;
  `uvm_component_utils(core_env)
  core_monitor    mon;
  core_scoreboard sb;
  core_coverage   cov;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    mon = core_monitor::type_id::create("mon", this);
    sb  = core_scoreboard::type_id::create("sb", this);
    cov = core_coverage::type_id::create("cov", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    mon.ap.connect(sb.analysis_export);
    mon.ap.connect(cov.analysis_export);
  endfunction
endclass
