// -----------------------------------------------------------------------------
// branch_predictor : adaptive branch prediction unit (top level)
//
//   Fetch side  : combinational lookup of {pred_taken, pred_target, meta} for pc_i.
//                 When the fetch actually advances (fetch_adv_i) the speculative
//                 state (global history register, return address stack) is updated.
//   Resolve side: the EX stage reports every resolved instruction through upd_i.
//                 Counters / BTB are trained and, on a mispredict, the speculative
//                 state is rolled back from the metadata saved at fetch time.
//
//   Components
//     * BTB          : decides *whether* a PC is a taken-type control-flow instruction
//     * bimodal      : PC-indexed 2-bit counters           (good for biased branches)
//     * gshare       : (PC xor global history) 2-bit ctrs  (good for correlated branches)
//     * choice table : PC-indexed 2-bit counters that learn, per branch, which of
//                      bimodal / gshare is currently more accurate  -> "adaptive"
//     * RAS          : return address stack for call/return pairs
// -----------------------------------------------------------------------------
module branch_predictor
  import bp_pkg::*;
#(
  parameter int unsigned PREDICTOR_TYPE = BP_TOURNAMENT,
  parameter int unsigned BIM_IDX_W      = 10,
  parameter int unsigned GSH_IDX_W      = 10,   // also the global-history length (2..16)
  parameter int unsigned CHO_IDX_W      = 10,
  parameter int unsigned BTB_IDX_W      = 6,
  parameter int unsigned BTB_TAG_W      = 16,
  parameter int unsigned RAS_DEPTH      = 8     // power of two, 2..16
) (
  input  logic              clk,
  input  logic              rst_n,

  // ---- fetch side ----------------------------------------------------------
  input  logic [XLEN-1:0]   pc_i,
  input  logic              fetch_adv_i,
  output logic              pred_taken_o,
  output logic [XLEN-1:0]   pred_target_o,
  output bp_meta_t          pred_meta_o,

  // ---- resolve side --------------------------------------------------------
  input  bp_update_t        upd_i
);

  localparam int unsigned RAS_PW = $clog2(RAS_DEPTH);

  // --------------------------------------------------------------------------
  // Speculative global history
  // --------------------------------------------------------------------------
  logic [GSH_IDX_W-1:0] ghr_q;

  // --------------------------------------------------------------------------
  // BTB
  // --------------------------------------------------------------------------
  logic            btb_hit;
  br_type_e        btb_type;
  logic [XLEN-1:0] btb_target;

  wire upd_is_ctrl = upd_i.is_cond | upd_i.is_jal | upd_i.is_jalr;

  br_type_e upd_type;
  always_comb begin
    if      (upd_i.is_ret)                    upd_type = BR_RET;
    else if (upd_i.is_call)                   upd_type = BR_CALL;
    else if (upd_i.is_jal | upd_i.is_jalr)    upd_type = BR_JUMP;
    else                                      upd_type = BR_COND;
  end

  // install taken control-flow, drop entries that aliased onto a non-branch
  wire btb_wr_en    = upd_i.valid & ((upd_is_ctrl & upd_i.taken) | (~upd_is_ctrl & upd_i.mispredict));
  wire btb_wr_valid = upd_is_ctrl;

  bp_btb #(.IDX_W(BTB_IDX_W), .TAG_W(BTB_TAG_W)) u_btb (
    .clk       (clk),
    .lookup_pc (pc_i),
    .hit       (btb_hit),
    .btype     (btb_type),
    .target    (btb_target),
    .wr_en     (btb_wr_en),
    .wr_valid  (btb_wr_valid),
    .wr_pc     (upd_i.pc),
    .wr_type   (upd_type),
    .wr_target (upd_i.target)
  );

  // --------------------------------------------------------------------------
  // Direction predictors
  // --------------------------------------------------------------------------
  wire [BIM_IDX_W-1:0] bim_idx  = pc_i[2 +: BIM_IDX_W];
  wire [GSH_IDX_W-1:0] gsh_idx  = pc_i[2 +: GSH_IDX_W] ^ ghr_q;
  wire [CHO_IDX_W-1:0] cho_idx  = pc_i[2 +: CHO_IDX_W];

  wire [BIM_IDX_W-1:0] bim_uidx = upd_i.pc[2 +: BIM_IDX_W];
  wire [GSH_IDX_W-1:0] gsh_uidx = upd_i.pc[2 +: GSH_IDX_W] ^ upd_i.meta.ghr[GSH_IDX_W-1:0];
  wire [CHO_IDX_W-1:0] cho_uidx = upd_i.pc[2 +: CHO_IDX_W];

  logic [1:0] bim_ctr, bim_uctr, gsh_ctr, gsh_uctr, cho_ctr, cho_uctr;

  wire train      = upd_i.valid & upd_i.is_cond;
  wire bim_ok     = (upd_i.meta.bim_taken == upd_i.taken);
  wire gsh_ok     = (upd_i.meta.gsh_taken == upd_i.taken);
  wire cho_train  = train & (bim_ok ^ gsh_ok);

  bp_counter_table #(.IDX_W(BIM_IDX_W), .INIT(2'b01)) u_bimodal (
    .clk(clk), .rd_idx(bim_idx), .rd_ctr(bim_ctr),
    .upd_idx(bim_uidx), .upd_ctr(bim_uctr),
    .wr_en(train), .wr_val(sat_update(bim_uctr, upd_i.taken))
  );

  bp_counter_table #(.IDX_W(GSH_IDX_W), .INIT(2'b01)) u_gshare (
    .clk(clk), .rd_idx(gsh_idx), .rd_ctr(gsh_ctr),
    .upd_idx(gsh_uidx), .upd_ctr(gsh_uctr),
    .wr_en(train), .wr_val(sat_update(gsh_uctr, upd_i.taken))
  );

  // choice counter: MSB=1 -> trust gshare, MSB=0 -> trust bimodal.
  // Only trained when the two components disagree; moves toward the correct one.
  bp_counter_table #(.IDX_W(CHO_IDX_W), .INIT(2'b01)) u_choice (
    .clk(clk), .rd_idx(cho_idx), .rd_ctr(cho_ctr),
    .upd_idx(cho_uidx), .upd_ctr(cho_uctr),
    .wr_en(cho_train), .wr_val(sat_update(cho_uctr, gsh_ok))
  );

  wire bim_taken = bim_ctr[1];
  wire gsh_taken = gsh_ctr[1];

  logic dir_taken;
  always_comb begin
    case (PREDICTOR_TYPE)
      BP_BIMODAL:    dir_taken = bim_taken;
      BP_GSHARE:     dir_taken = gsh_taken;
      BP_TOURNAMENT: dir_taken = cho_ctr[1] ? gsh_taken : bim_taken;
      default:       dir_taken = 1'b0;
    endcase
  end

  // --------------------------------------------------------------------------
  // Return address stack
  // --------------------------------------------------------------------------
  logic [XLEN-1:0]    ras_top;
  logic [RAS_PW-1:0]  ras_ptr;

  wire recover  = upd_i.valid & upd_i.mispredict;
  wire pred_hit = (PREDICTOR_TYPE != BP_NONE) & btb_hit;
  wire spec_en  = fetch_adv_i & ~recover & pred_hit;

  bp_ras #(.DEPTH(RAS_DEPTH)) u_ras (
    .clk           (clk),
    .rst_n         (rst_n),
    .top           (ras_top),
    .ptr           (ras_ptr),
    .push          (spec_en & (btb_type == BR_CALL)),
    .push_data     (pc_i + XLEN'(4)),
    .pop           (spec_en & (btb_type == BR_RET)),
    .rec_en        (recover),
    .rec_ptr       (upd_i.meta.ras_ptr[RAS_PW-1:0]),
    .rec_push      (upd_i.is_call),
    .rec_push_data (upd_i.pc + XLEN'(4)),
    .rec_pop       (upd_i.is_ret)
  );

  // --------------------------------------------------------------------------
  // Global history register: speculative shift at fetch, repair at mispredict.
  // Only conditional branches that hit in the BTB shift the history; on a
  // mispredict the history is rebuilt from the pre-fetch snapshot plus the
  // actual outcome (if the resolved instruction is a conditional branch).
  // --------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ghr_q <= '0;
    end else if (recover) begin
      ghr_q <= upd_i.is_cond ? GSH_IDX_W'({upd_i.meta.ghr, upd_i.taken})
                             : upd_i.meta.ghr[GSH_IDX_W-1:0];
    end else if (spec_en && btb_type == BR_COND) begin
      ghr_q <= GSH_IDX_W'({ghr_q, dir_taken});
    end
  end

  // --------------------------------------------------------------------------
  // Outputs
  // --------------------------------------------------------------------------
  assign pred_taken_o  = pred_hit & ((btb_type != BR_COND) | dir_taken);
  assign pred_target_o = (btb_type == BR_RET) ? ras_top : btb_target;

  always_comb begin
    pred_meta_o           = '0;
    pred_meta_o.ghr       = 16'(ghr_q);
    pred_meta_o.bim_taken = bim_taken;
    pred_meta_o.gsh_taken = gsh_taken;
    pred_meta_o.dir_taken = dir_taken;
    pred_meta_o.ras_ptr   = 4'(ras_ptr);
  end

endmodule
