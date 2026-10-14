// -----------------------------------------------------------------------------
// bp_item : one *correct-path* dynamic instruction of the synthetic program stream
// bp_mon_item : what the monitor observes in one clock cycle
// -----------------------------------------------------------------------------
typedef enum {K_NONE, K_COND, K_JAL, K_CALL, K_RET, K_JALR, K_ICALL} bp_kind_e;

class bp_item extends uvm_sequence_item;
  bit [63:0] pc;
  bp_kind_e  kind;
  bit        taken;       // actual outcome
  bit [63:0] target;      // actual target (valid when taken)

  `uvm_object_utils_begin(bp_item)
    `uvm_field_int(pc, UVM_DEFAULT | UVM_HEX)
    `uvm_field_enum(bp_kind_e, kind, UVM_DEFAULT)
    `uvm_field_int(taken, UVM_DEFAULT)
    `uvm_field_int(target, UVM_DEFAULT | UVM_HEX)
  `uvm_object_utils_end

  function new(string name = "bp_item");
    super.new(name);
  endfunction

  function bit [63:0] actual_next();
    return taken ? target : pc + 4;
  endfunction
endclass

class bp_mon_item extends uvm_object;
  bit              rst_n;
  bit [63:0]       pc;
  bit              adv;
  bp_pkg::bp_update_t upd;
  bit              pred_taken;
  bit [63:0]       pred_target;
  bp_pkg::bp_meta_t pred_meta;

  `uvm_object_utils(bp_mon_item)
  function new(string name = "bp_mon_item");
    super.new(name);
  endfunction
endclass
