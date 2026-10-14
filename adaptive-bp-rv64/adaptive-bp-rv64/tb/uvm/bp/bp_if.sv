// -----------------------------------------------------------------------------
// bp_if : interface of the branch predictor unit, with protocol assertions + cover points
// -----------------------------------------------------------------------------
interface bp_if (input logic clk, input int unsigned ptype);
  import bp_pkg::*;

  logic        rst_n = 1'b0;
  // fetch side
  logic [63:0] pc  = '0;
  logic        adv = 1'b0;
  logic        pred_taken;
  logic [63:0] pred_target;
  bp_meta_t    pred_meta;
  // resolve side
  bp_update_t  upd = '0;

  clocking drv_cb @(posedge clk);
    default input #1step output #1;
    output rst_n, pc, adv, upd;
    input  pred_taken, pred_target, pred_meta;
  endclocking

  clocking mon_cb @(posedge clk);
    default input #1step;
    input rst_n, pc, adv, upd, pred_taken, pred_target, pred_meta;
  endclocking

  // ---------------------------------------------------------------------------
  // Assertions (checked on the DUT-facing signals every clock)
  // ---------------------------------------------------------------------------
  // A1: outputs are never X/Z once out of reset and a defined PC is applied
  property p_no_x;
    @(posedge clk) disable iff (!rst_n || $isunknown(pc))
      !$isunknown({pred_taken, pred_meta}) && (!pred_taken || !$isunknown(pred_target));
  endproperty
  a_no_x: assert property (p_no_x) else $error("[bp_if] X/Z on predictor outputs");

  // A2: BP_NONE never predicts taken
  a_none_never_taken: assert property (@(posedge clk) disable iff (!rst_n || $isunknown(pc))
      (ptype == BP_NONE) |-> !pred_taken)
    else $error("[bp_if] BP_NONE predicted taken");

  // A3: predicted targets are word aligned
  a_target_aligned: assert property (@(posedge clk) disable iff (!rst_n || $isunknown(pc))
      pred_taken |-> (pred_target[1:0] == 2'b00))
    else $error("[bp_if] unaligned predicted target %h", pred_target);

  // A4: with no state-changing event in the previous cycle and an unchanged PC the
  //     combinational prediction must be identical (no hidden state changes)
  a_stable: assert property (@(posedge clk) disable iff (!rst_n || $isunknown(pc))
      ($past(!(adv || upd.valid)) && (pc == $past(pc)) && $past(rst_n)) |->
        (pred_taken == $past(pred_taken) && pred_meta == $past(pred_meta) &&
         (!pred_taken || pred_target == $past(pred_target))))
    else $error("[bp_if] prediction changed without a state-changing event");

  // A5: resolution bundle sanity
  a_upd_onehot: assert property (@(posedge clk) disable iff (!rst_n)
      upd.valid |-> $onehot0({upd.is_cond, upd.is_jal, upd.is_jalr}))
    else $error("[bp_if] more than one control type flagged");
  a_upd_jump_taken: assert property (@(posedge clk) disable iff (!rst_n)
      (upd.valid && (upd.is_jal || upd.is_jalr)) |-> upd.taken)
    else $error("[bp_if] jal/jalr resolved as not-taken");
  a_upd_call_ret_excl: assert property (@(posedge clk) disable iff (!rst_n)
      upd.valid |-> !(upd.is_call && upd.is_ret))
    else $error("[bp_if] call and ret flagged together");

  // ---- cover properties -------------------------------------------------------
  c_recover_with_fetch: cover property (@(posedge clk) disable iff (!rst_n)
      upd.valid && upd.mispredict && adv);
  c_ret_predicted:      cover property (@(posedge clk) disable iff (!rst_n)
      pred_taken && (pred_target != '0) && upd.valid && upd.is_ret);
  c_back_to_back_mis:   cover property (@(posedge clk) disable iff (!rst_n)
      (upd.valid && upd.mispredict) ##1 (upd.valid && upd.mispredict));
endinterface
