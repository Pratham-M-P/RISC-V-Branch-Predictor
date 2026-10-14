// Configuration object shared by test / env / driver / scoreboard
class bp_cfg extends uvm_object;
  `uvm_object_utils(bp_cfg)

  // must mirror the DUT parameters (set by the top module)
  int unsigned ptype  = bp_pkg::BP_TOURNAMENT;
  int unsigned bim_w  = 10;
  int unsigned gsh_w  = 10;
  int unsigned cho_w  = 10;
  int unsigned btb_w  = 6;
  int unsigned tag_w  = 16;
  int unsigned ras_d  = 8;

  // stimulus knobs
  int unsigned pipe_lat   = 2;            // fetch -> resolve distance in cycles (>=1)
  int unsigned stall_pct  = 10;           // probability (%) that fetch does not advance
  bit [63:0]   code_base  = 64'h1000;
  int unsigned code_words = 192;          // size of the synthetic code region (words)

  function new(string name = "bp_cfg");
    super.new(name);
  endfunction
endclass
