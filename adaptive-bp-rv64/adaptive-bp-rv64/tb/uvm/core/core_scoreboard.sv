// -----------------------------------------------------------------------------
// core_scoreboard : pipeline-level checking against the golden ISS trace (+GOLDEN=<file>)
//   1. every committed instruction == golden record (pc, encoding, rd, write data), in order
//   2. every resolved control-flow instruction == next golden control instruction
//      (pc, direction, target) -> resolution is always on the architectural path
//   3. the core's own misprediction flag is re-derived and checked
//   4. at end of test: commit / branch / mispredict counts == performance counters
// -----------------------------------------------------------------------------
class core_scoreboard extends uvm_subscriber #(core_cyc_item);
  `uvm_component_utils(core_scoreboard)

  core_gold_rec gold[$];
  int unsigned  gold_ctrl_idx[$];              // indices into gold[] of control-flow instructions
  int unsigned  n_commit, n_res, n_res_cond, n_res_mis, n_res_cond_mis, n_err;
  bit           have_gold;
  core_cyc_item last;

  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    load_golden();
  endfunction

  function void load_golden();
    string fname;
    int fd;
    if (!$value$plusargs("GOLDEN=%s", fname)) begin
      `uvm_warning("SB", "no +GOLDEN=<trace>: commit/branch checking disabled (assertions + counters only)")
      return;
    end
    fd = $fopen(fname, "r");
    if (fd == 0) `uvm_fatal("SB", $sformatf("cannot open golden trace %s", fname))
    while (!$feof(fd)) begin
      core_gold_rec r = new();
      int n = $fscanf(fd, "%h %h %d %h\n", r.pc, r.instr, r.rd, r.data);
      if (n == 4) begin
        if (r.is_ctrl()) gold_ctrl_idx.push_back(gold.size());
        gold.push_back(r);
      end
    end
    $fclose(fd);
    have_gold = 1;
    `uvm_info("SB", $sformatf("loaded %0d golden commits (%0d control-flow)", gold.size(), gold_ctrl_idx.size()), UVM_LOW)
  endfunction

  function void write(core_cyc_item t);
    last = t;
    if (!t.rst_n) return;

    // ---- (1) commit stream ----------------------------------------------------------------
    if (t.commit_valid) begin
      if (have_gold) begin
        if (n_commit >= gold.size()) begin
          n_err++; `uvm_error("SB_COMMIT", $sformatf("extra commit #%0d pc=%h", n_commit, t.commit_pc))
        end else begin
          core_gold_rec g = gold[n_commit];
          if (g.pc !== t.commit_pc || g.instr !== t.commit_instr || g.rd !== t.commit_rd || g.data !== t.commit_data) begin
            n_err++;
            `uvm_error("SB_COMMIT", $sformatf("commit #%0d mismatch: DUT pc=%h insn=%h rd=%0d data=%h | GOLD pc=%h insn=%h rd=%0d data=%h",
                       n_commit, t.commit_pc, t.commit_instr, t.commit_rd, t.commit_data, g.pc, g.instr, g.rd, g.data))
          end
        end
      end
      n_commit++;
    end

    // ---- (2),(3) branch resolution ----------------------------------------------------------
    if (t.res_valid) begin
      bit [63:0] pred_next = t.res_pred_taken ? t.res_pred_target : t.res_pc + 4;
      bit [63:0] act_next  = t.res_taken ? t.res_target : t.res_pc + 4;
      if (t.res_mispredict !== (pred_next != act_next)) begin
        n_err++; `uvm_error("SB_MIS", $sformatf("pc=%h mispredict flag %0b but pred_next=%h actual_next=%h",
                                                 t.res_pc, t.res_mispredict, pred_next, act_next))
      end
      if (have_gold) begin
        if (n_res >= gold_ctrl_idx.size()) begin
          n_err++; `uvm_error("SB_BR", $sformatf("unexpected extra resolved branch pc=%h", t.res_pc))
        end else begin
          int unsigned gi = gold_ctrl_idx[n_res];
          core_gold_rec g = gold[gi];
          bit [63:0] gnext = (gi + 1 < gold.size()) ? gold[gi + 1].pc : 64'hx;
          bit        gtaken = (gnext != g.pc + 4);
          if (g.pc !== t.res_pc) begin
            n_err++; `uvm_error("SB_BR", $sformatf("branch #%0d: DUT resolved pc=%h, golden expects pc=%h", n_res, t.res_pc, g.pc))
          end else if (gi + 1 < gold.size()) begin
            // a conditional branch whose target equals pc+4 is indistinguishable by next-PC
            bit ambiguous = g.is_cond() && (t.res_target == g.pc + 4);
            if (!ambiguous && t.res_taken !== gtaken) begin
              n_err++; `uvm_error("SB_BR", $sformatf("branch pc=%h direction DUT=%0b golden=%0b", t.res_pc, t.res_taken, gtaken))
            end else if (gtaken && t.res_target !== gnext) begin
              n_err++; `uvm_error("SB_BR", $sformatf("branch pc=%h target DUT=%h golden=%h", t.res_pc, t.res_target, gnext))
            end
          end
        end
      end
      n_res++;
      if (t.res_is_cond) begin n_res_cond++; n_res_cond_mis += t.res_mispredict; end
      n_res_mis += t.res_mispredict;
    end
  endfunction

  function void check_phase(uvm_phase phase);
    if (last == null) begin
      `uvm_error("SB", "no cycles observed")
      return;
    end
    if (!last.halted) `uvm_error("SB", "program did not halt (timeout?)")
    if (have_gold) begin
      if (n_commit != gold.size())
        `uvm_error("SB_COUNT", $sformatf("commit count DUT=%0d golden=%0d", n_commit, gold.size()))
      if (n_res != gold_ctrl_idx.size())
        `uvm_error("SB_COUNT", $sformatf("resolved control-flow count DUT=%0d golden=%0d", n_res, gold_ctrl_idx.size()))
    end
    if (last.perf_instret   != n_commit)      `uvm_error("SB_PERF", $sformatf("perf_instret=%0d observed=%0d", last.perf_instret, n_commit))
    if (last.perf_ctrl      != n_res)         `uvm_error("SB_PERF", $sformatf("perf_ctrl=%0d observed=%0d", last.perf_ctrl, n_res))
    if (last.perf_cond_br   != n_res_cond)    `uvm_error("SB_PERF", $sformatf("perf_cond_br=%0d observed=%0d", last.perf_cond_br, n_res_cond))
    if (last.perf_cond_mispred != n_res_cond_mis)
      `uvm_error("SB_PERF", $sformatf("perf_cond_mispred=%0d observed=%0d", last.perf_cond_mispred, n_res_cond_mis))
    if (last.perf_ctrl_mispred != n_res_mis)  `uvm_error("SB_PERF", $sformatf("perf_ctrl_mispred=%0d observed=%0d", last.perf_ctrl_mispred, n_res_mis))
  endfunction

  function void report_phase(uvm_phase phase);
    real acc = (n_res_cond != 0) ? 100.0 * (1.0 - real'(n_res_cond_mis) / real'(n_res_cond)) : 100.0;
    `uvm_info("SB", $sformatf("commits=%0d branches=%0d (cond %0d, mispredicted %0d) accuracy=%.2f%% cycles=%0d IPC=%.3f",
              n_commit, n_res, n_res_cond, n_res_cond_mis, acc, last.perf_cycles,
              real'(n_commit) / real'(last.perf_cycles)), UVM_LOW)
  endfunction
endclass
