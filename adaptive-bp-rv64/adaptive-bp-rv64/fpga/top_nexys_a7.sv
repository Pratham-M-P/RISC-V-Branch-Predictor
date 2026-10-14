// -----------------------------------------------------------------------------
// top_nexys_a7 : Digilent Nexys A7-100T (XC7A100T-1CSG324C) board wrapper
//
//   100 MHz board clock -> MMCM -> 50 MHz core clock (CORE_CLK_DIV = 20 -> 1000/20)
//   CPU_RESETN (button)  -> synchronised, released only once the MMCM has locked
//   LEDs show a 16-bit slice selected by SW[2:0]:
//        0  GPIO register (demo: bit15 = done, [7:0] = accuracy %)
//        1  conditional mispredicts [15:0]      2  conditional branches [15:0]
//        3  cycles [15:0]                       4  cycles [31:16]
//        5  instructions retired [15:0]         6  instructions retired [31:16]
//        7  {halted, illegal, 14'b0}
//   SW[15] = 1 holds the core in reset (handy to restart the demo).
// -----------------------------------------------------------------------------
module top_nexys_a7 #(
  parameter string       IMEM_INIT      = "program.hex",
  parameter string       DMEM_INIT      = "",
  parameter int unsigned PREDICTOR_TYPE = 3,
  parameter real         CORE_CLK_DIV   = 20.0       // MMCM VCO = 1000 MHz
) (
  input  logic        CLK100MHZ,
  input  logic        CPU_RESETN,
  input  logic [15:0] SW,
  output logic [15:0] LED
);
  // ---- clocking ----------------------------------------------------------------
  logic clk_fb, clk_core_raw, clk_core, locked;

  MMCME2_BASE #(
    .BANDWIDTH        ("OPTIMIZED"),
    .CLKIN1_PERIOD    (10.0),
    .DIVCLK_DIVIDE    (1),
    .CLKFBOUT_MULT_F  (10.0),
    .CLKOUT0_DIVIDE_F (CORE_CLK_DIV)
  ) u_mmcm (
    .CLKIN1   (CLK100MHZ),
    .CLKFBIN  (clk_fb),
    .CLKFBOUT (clk_fb),
    .CLKOUT0  (clk_core_raw),
    .LOCKED   (locked),
    .PWRDWN   (1'b0),
    .RST      (1'b0),
    .CLKFBOUTB(), .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(),
    .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6()
  );
  BUFG u_bufg (.I(clk_core_raw), .O(clk_core));

  // ---- reset synchroniser -------------------------------------------------------
  logic [3:0] rst_sync = 4'b0000;
  wire        rst_req_n = CPU_RESETN & ~SW[15] & locked;
  always_ff @(posedge clk_core or negedge rst_req_n) begin
    if (!rst_req_n) rst_sync <= 4'b0000;
    else            rst_sync <= {rst_sync[2:0], 1'b1};
  end
  wire rst_n = rst_sync[3];

  // ---- SoC -----------------------------------------------------------------------
  logic [63:0] gpio;
  logic        halted, illegal;
  logic [63:0] p_cyc, p_ret, p_cond, p_mp, p_ctrl, p_ctrl_mp;

  rv64_soc #(
    .PREDICTOR_TYPE (PREDICTOR_TYPE),
    .IMEM_INIT      (IMEM_INIT),
    .DMEM_INIT      (DMEM_INIT)
  ) u_soc (
    .clk(clk_core), .rst_n(rst_n),
    .gpio_out(gpio), .halted_o(halted), .illegal_o(illegal),
    .commit_valid(), .commit_pc(), .commit_instr(), .commit_rd(), .commit_data(),
    .res_valid(), .res_pc(), .res_is_cond(), .res_is_ctrl(), .res_taken(), .res_target(),
    .res_pred_taken(), .res_pred_target(), .res_mispredict(),
    .stall_o(),
    .perf_cycles(p_cyc), .perf_instret(p_ret), .perf_cond_br(p_cond),
    .perf_cond_mispred(p_mp), .perf_ctrl(p_ctrl), .perf_ctrl_mispred(p_ctrl_mp)
  );

  // ---- display mux (registered: keeps the LED path off the critical path) ---------------
  always_ff @(posedge clk_core) begin
    case (SW[2:0])
      3'd0:    LED <= gpio[15:0];
      3'd1:    LED <= p_mp[15:0];
      3'd2:    LED <= p_cond[15:0];
      3'd3:    LED <= p_cyc[15:0];
      3'd4:    LED <= p_cyc[31:16];
      3'd5:    LED <= p_ret[15:0];
      3'd6:    LED <= p_ret[31:16];
      default: LED <= {halted, illegal, 14'b0};
    endcase
  end
endmodule
