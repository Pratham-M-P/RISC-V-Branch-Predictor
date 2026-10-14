// -----------------------------------------------------------------------------
// bp_uvm_pkg : UVM environment for the branch prediction unit
// -----------------------------------------------------------------------------
package bp_uvm_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import bp_pkg::*;

  `include "bp_ref_model.sv"
  `include "bp_cfg.sv"
  `include "bp_item.sv"
  `include "bp_sequences.sv"
  `include "bp_driver.sv"
  `include "bp_monitor.sv"
  `include "bp_scoreboard.sv"
  `include "bp_coverage.sv"
  `include "bp_env.sv"
  `include "bp_tests.sv"
endpackage
