// -----------------------------------------------------------------------------
// tb_bp_model_check : plain-SV random equivalence check, RTL branch_predictor vs
//                     bp_ref_model, every cycle.  Runs under Verilator (no UVM needed),
//                     used in CI to validate the model that the UVM scoreboard relies on.
//   +CYCLES=<n>  +SEED=<n>
// -----------------------------------------------------------------------------
module tb_bp_model_check;
  import bp_pkg::*;
  `include "uvm/bp/bp_ref_model.sv"

  parameter int unsigned PREDICTOR_TYPE = BP_TOURNAMENT;
  parameter int unsigned BIM_IDX_W = 6, GSH_IDX_W = 6, CHO_IDX_W = 6, BTB_IDX_W = 4, BTB_TAG_W = 8, RAS_DEPTH = 4;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic [63:0] pc;
  logic        adv;
  bp_update_t  upd;
  logic        p_taken;
  logic [63:0] p_target;
  bp_meta_t    p_meta;

  branch_predictor #(.PREDICTOR_TYPE(PREDICTOR_TYPE), .BIM_IDX_W(BIM_IDX_W), .GSH_IDX_W(GSH_IDX_W),
    .CHO_IDX_W(CHO_IDX_W), .BTB_IDX_W(BTB_IDX_W), .BTB_TAG_W(BTB_TAG_W), .RAS_DEPTH(RAS_DEPTH)) dut (
    .clk, .rst_n, .pc_i(pc), .fetch_adv_i(adv), .pred_taken_o(p_taken), .pred_target_o(p_target),
    .pred_meta_o(p_meta), .upd_i(upd));

  bp_ref_model m;
  int unsigned cycles = 50000, seed = 1, errors = 0, hits = 0, recov = 0;

  function automatic logic [63:0] rnd_pc();
    // small pool with BTB aliasing (stride of 2^(BTB_IDX_W+2) bytes)
    return 64'h1000 + 64'(4 * ($urandom_range(0, 40))) + (64'(1) << (BTB_IDX_W + 2)) * $urandom_range(0, 2);
  endfunction

  initial begin
    void'($value$plusargs("CYCLES=%d", cycles));
    void'($value$plusargs("SEED=%d", seed));
    void'($urandom(seed));
    m = new(PREDICTOR_TYPE, BIM_IDX_W, GSH_IDX_W, CHO_IDX_W, BTB_IDX_W, BTB_TAG_W, RAS_DEPTH);
    pc = 0; adv = 0; upd = '0;
    repeat (3) @(posedge clk);
    #1 rst_n = 1; m.reset();

    repeat (cycles) begin
      // ---- drive for this cycle (changes after the previous edge) -----------------
      pc  = rnd_pc();
      adv = ($urandom_range(0, 9) != 0);
      upd = '0;
      if ($urandom_range(0, 2) != 0) begin
        int k = $urandom_range(0, 9);
        upd.valid = 1;
        upd.pc    = rnd_pc();
        upd.meta.ghr       = 16'($urandom());
        upd.meta.bim_taken = $urandom_range(0, 1);
        upd.meta.gsh_taken = $urandom_range(0, 1);
        upd.meta.dir_taken = $urandom_range(0, 1);
        upd.meta.ras_ptr   = 4'($urandom_range(0, RAS_DEPTH - 1));
        upd.target         = rnd_pc();
        upd.mispredict     = ($urandom_range(0, 3) == 0);
        case (k)
          0, 1, 2, 3: begin upd.is_cond = 1; upd.taken = $urandom_range(0, 1); end
          4, 5:       begin upd.is_jal  = 1; upd.taken = 1; upd.is_call = $urandom_range(0, 1); end
          6, 7:       begin upd.is_jalr = 1; upd.taken = 1; upd.is_call = $urandom_range(0, 1);
                            upd.is_ret = !upd.is_call && $urandom_range(0, 1); end
          default:    begin upd.taken = 0; end    // non-control instruction (possible alias mispredict)
        endcase
      end
      #1;   // let combinational outputs settle
      begin
        bit e_taken; bit [63:0] e_target; bp_meta_t e_meta;
        m.predict(pc, e_taken, e_target, e_meta);
        if (e_taken !== p_taken || (e_taken && e_target !== p_target) || e_meta !== p_meta) begin
          errors++;
          if (errors < 10)
            $display("MISMATCH t=%0t pc=%h exp(taken=%0b tgt=%h meta=%h) dut(taken=%0b tgt=%h meta=%h)",
                     $time, pc, e_taken, e_target, e_meta, p_taken, p_target, p_meta);
        end
        hits += p_taken;
        recov += (upd.valid && upd.mispredict);
      end
      @(posedge clk);
      m.step(pc, adv, upd);
      #1;   // never change inputs in the same time step as the clock edge
    end
    $display("MODEL_CHECK ptype=%0d cycles=%0d predicted_taken=%0d recoveries=%0d errors=%0d",
             PREDICTOR_TYPE, cycles, hits, recov, errors);
    if (errors == 0) $display("PASS"); else $display("FAIL");
    $finish;
  end
endmodule
