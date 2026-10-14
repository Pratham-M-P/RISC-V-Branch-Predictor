// -----------------------------------------------------------------------------
// bp_pkg : shared types for the adaptive branch prediction unit
// -----------------------------------------------------------------------------
package bp_pkg;

  localparam int unsigned XLEN = 64;

  // Predictor flavours selectable through the PREDICTOR_TYPE parameter
  localparam int unsigned BP_NONE       = 0;  // always predict not-taken (baseline)
  localparam int unsigned BP_BIMODAL    = 1;  // PC-indexed 2-bit counters
  localparam int unsigned BP_GSHARE     = 2;  // global history XOR PC
  localparam int unsigned BP_TOURNAMENT = 3;  // adaptive: bimodal vs gshare, chosen by a meta predictor

  // Type of control-flow instruction stored in the BTB
  typedef enum logic [1:0] {
    BR_COND = 2'd0,   // conditional branch, direction from the direction predictor
    BR_JUMP = 2'd1,   // unconditional jump (jal / non-return jalr), target from BTB
    BR_CALL = 2'd2,   // call: like JUMP, additionally pushes the return address on the RAS
    BR_RET  = 2'd3    // return: target from the RAS
  } br_type_e;

  // Speculative-state snapshot that travels down the pipeline with the
  // instruction and is handed back at resolution time (training + recovery).
  typedef struct packed {
    logic [15:0] ghr;        // global history *before* this fetch (zero-extended)
    logic        bim_taken;  // bimodal component prediction
    logic        gsh_taken;  // gshare component prediction
    logic        dir_taken;  // direction finally selected
    logic [3:0]  ras_ptr;    // RAS pointer *before* this fetch
  } bp_meta_t;

  // Update / resolution bundle, produced by the EX stage
  typedef struct packed {
    logic             valid;       // an instruction is resolved this cycle
    logic [XLEN-1:0]  pc;
    logic             is_cond;     // conditional branch
    logic             is_jal;
    logic             is_jalr;
    logic             is_call;
    logic             is_ret;
    logic             taken;       // actual outcome (always 1 for jal/jalr)
    logic [XLEN-1:0]  target;      // actual target when taken
    logic             mispredict;  // next-PC differed from the predicted next-PC
    bp_meta_t         meta;
  } bp_update_t;

  // 2-bit saturating counter update
  function automatic logic [1:0] sat_update(input logic [1:0] c, input logic taken);
    if (taken) return (c == 2'b11) ? 2'b11 : c + 2'b01;
    else       return (c == 2'b00) ? 2'b00 : c - 2'b01;
  endfunction

endpackage
