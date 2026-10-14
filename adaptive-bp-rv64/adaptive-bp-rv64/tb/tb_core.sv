// -----------------------------------------------------------------------------
// tb_core : plain SystemVerilog self-running testbench (Verilator / xsim / Questa)
//
//   +HEX=<file>       instruction image (32-bit words, $readmemh)
//   +DHEX=<file>      optional data image (64-bit words)
//   +TRACE=<file>     write the commit trace (compared against the Python ISS)
//   +MAXCYCLES=<n>    watchdog (default 2,000,000)
//   +QUIET            suppress the summary banner (machine-readable line still printed)
//
// Final line printed:  RESULT cycles=.. instret=.. cond_br=.. cond_mp=.. ctrl=.. ctrl_mp=.. a0=.. halted=.. illegal=..
// -----------------------------------------------------------------------------
module tb_core;
  parameter int unsigned PREDICTOR_TYPE = 3;
  parameter int unsigned BIM_IDX_W      = 10;
  parameter int unsigned GSH_IDX_W      = 10;
  parameter int unsigned CHO_IDX_W      = 10;
  parameter int unsigned BTB_IDX_W      = 6;
  parameter int unsigned RAS_DEPTH      = 8;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  logic [63:0] gpio_out;
  logic        halted, illegal;
  logic        commit_valid;
  logic [63:0] commit_pc, commit_data;
  logic [31:0] commit_instr;
  logic [4:0]  commit_rd;
  logic        res_valid, res_is_cond, res_is_ctrl, res_taken, res_pred_taken, res_mispredict;
  logic [63:0] res_pc, res_target, res_pred_target;
  logic        stall_o;
  logic [63:0] p_cycles, p_instret, p_cond, p_cond_mp, p_ctrl, p_ctrl_mp;

  rv64_soc #(
    .PREDICTOR_TYPE(PREDICTOR_TYPE), .BIM_IDX_W(BIM_IDX_W), .GSH_IDX_W(GSH_IDX_W),
    .CHO_IDX_W(CHO_IDX_W), .BTB_IDX_W(BTB_IDX_W), .RAS_DEPTH(RAS_DEPTH)
  ) dut (
    .clk, .rst_n, .gpio_out, .halted_o(halted), .illegal_o(illegal),
    .commit_valid, .commit_pc, .commit_instr, .commit_rd, .commit_data,
    .res_valid, .res_pc, .res_is_cond, .res_is_ctrl, .res_taken, .res_target,
    .res_pred_taken, .res_pred_target, .res_mispredict,
    .stall_o,
    .perf_cycles(p_cycles), .perf_instret(p_instret), .perf_cond_br(p_cond),
    .perf_cond_mispred(p_cond_mp), .perf_ctrl(p_ctrl), .perf_ctrl_mispred(p_ctrl_mp)
  );

  integer trace_fd = 0;
  string  trace_file;
  int     max_cycles = 2000000;
  int     cyc = 0;

  initial begin
    if ($value$plusargs("TRACE=%s", trace_file)) trace_fd = $fopen(trace_file, "w");
    void'($value$plusargs("MAXCYCLES=%d", max_cycles));
    repeat (4) @(posedge clk);
    #1 rst_n = 1'b1;
  end

  always @(posedge clk) begin
    if (rst_n && commit_valid && trace_fd != 0)
      $fwrite(trace_fd, "%016h %08h %0d %016h\n", commit_pc, commit_instr, commit_rd, commit_data);
  end

  always @(posedge clk) begin
    if (rst_n) begin
      cyc <= cyc + 1;
      if (halted || cyc >= max_cycles) begin
        repeat (2) @(posedge clk);
        if (trace_fd != 0) $fclose(trace_fd);
        if (!$test$plusargs("QUIET"))
          $display("---- run %s after %0d cycles", halted ? "halted" : "TIMED OUT", cyc);
        $display("RESULT cycles=%0d instret=%0d cond_br=%0d cond_mp=%0d ctrl=%0d ctrl_mp=%0d a0=%0d halted=%0d illegal=%0d",
                 p_cycles, p_instret, p_cond, p_cond_mp, p_ctrl, p_ctrl_mp,
                 $signed(dut.u_core.u_rf.regs[10]), halted, illegal);
        $finish;
      end
    end
  end
endmodule
