class bp_agent extends uvm_agent;
  `uvm_component_utils(bp_agent)
  uvm_sequencer #(bp_item) sqr;
  bp_driver  drv;
  bp_monitor mon;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    sqr = uvm_sequencer#(bp_item)::type_id::create("sqr", this);
    drv = bp_driver::type_id::create("drv", this);
    mon = bp_monitor::type_id::create("mon", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass

class bp_env extends uvm_env;
  `uvm_component_utils(bp_env)
  bp_agent      agent;
  bp_scoreboard sb;
  bp_coverage   cov;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    agent = bp_agent::type_id::create("agent", this);
    sb    = bp_scoreboard::type_id::create("sb", this);
    cov   = bp_coverage::type_id::create("cov", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    agent.mon.ap.connect(sb.analysis_export);
    agent.mon.ap.connect(cov.analysis_export);
  endfunction
endclass
