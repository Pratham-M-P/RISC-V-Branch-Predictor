// -----------------------------------------------------------------------------
// rv64_soc : core + instruction memory + data memory + tiny MMIO block
//
//   Data address map (Harvard: instruction memory is a separate space at 0)
//     0x0000_0000 .. DMEM_BYTES-1 : data RAM
//     0x8000_0000                 : GPIO_OUT   (R/W, 64 bit)  -> LEDs on the FPGA
//     0x8000_0010                 : cycle counter        (RO)
//     0x8000_0018                 : instructions retired (RO)
//     0x8000_0020                 : conditional branches (RO)
//     0x8000_0028                 : conditional mispredicts (RO)
//     0x8000_0030                 : all control-flow instructions (RO)
//     0x8000_0038                 : all control-flow mispredicts (RO)
// -----------------------------------------------------------------------------
module rv64_soc #(
  parameter int unsigned PREDICTOR_TYPE = 3,
  parameter int unsigned BIM_IDX_W      = 10,
  parameter int unsigned GSH_IDX_W      = 10,
  parameter int unsigned CHO_IDX_W      = 10,
  parameter int unsigned BTB_IDX_W      = 6,
  parameter int unsigned BTB_TAG_W      = 16,
  parameter int unsigned RAS_DEPTH      = 8,
  parameter int unsigned IMEM_AW        = 12,
  parameter int unsigned DMEM_AW        = 11,
  parameter string       IMEM_INIT      = "",
  parameter string       DMEM_INIT      = ""
) (
  input  logic        clk,
  input  logic        rst_n,

  output logic [63:0] gpio_out,
  output logic        halted_o,
  output logic        illegal_o,

  // verification / statistics taps
  output logic        commit_valid,
  output logic [63:0] commit_pc,
  output logic [31:0] commit_instr,
  output logic [4:0]  commit_rd,
  output logic [63:0] commit_data,

  output logic        res_valid,
  output logic [63:0] res_pc,
  output logic        res_is_cond,
  output logic        res_is_ctrl,
  output logic        res_taken,
  output logic [63:0] res_target,
  output logic        res_pred_taken,
  output logic [63:0] res_pred_target,
  output logic        res_mispredict,

  output logic        stall_o,
  output logic [63:0] perf_cycles,
  output logic [63:0] perf_instret,
  output logic [63:0] perf_cond_br,
  output logic [63:0] perf_cond_mispred,
  output logic [63:0] perf_ctrl,
  output logic [63:0] perf_ctrl_mispred
);
  logic [63:0] imem_addr;  logic [31:0] imem_rdata;
  logic [63:0] dmem_addr, dmem_wdata, dmem_rdata;
  logic        dmem_re, dmem_we;
  logic [7:0]  dmem_be;

  rv64_core #(
    .PREDICTOR_TYPE(PREDICTOR_TYPE), .BIM_IDX_W(BIM_IDX_W), .GSH_IDX_W(GSH_IDX_W),
    .CHO_IDX_W(CHO_IDX_W), .BTB_IDX_W(BTB_IDX_W), .BTB_TAG_W(BTB_TAG_W), .RAS_DEPTH(RAS_DEPTH)
  ) u_core (
    .clk, .rst_n,
    .imem_addr, .imem_rdata,
    .dmem_addr, .dmem_re, .dmem_we, .dmem_be, .dmem_wdata, .dmem_rdata,
    .commit_valid, .commit_pc, .commit_instr, .commit_rd, .commit_data,
    .res_valid, .res_pc, .res_is_cond, .res_is_ctrl, .res_taken, .res_target,
    .res_pred_taken, .res_pred_target, .res_mispredict,
    .halted_o, .illegal_o, .stall_o,
    .perf_cycles, .perf_instret, .perf_cond_br, .perf_cond_mispred,
    .perf_ctrl, .perf_ctrl_mispred
  );

  rv64_imem #(.AW(IMEM_AW), .INIT_FILE(IMEM_INIT)) u_imem (.addr(imem_addr), .rdata(imem_rdata));

  // ---- address decode -------------------------------------------------------
  wire is_mmio = dmem_addr[31];
  logic [63:0] ram_rdata, mmio_rdata;

  rv64_dmem #(.AW(DMEM_AW), .INIT_FILE(DMEM_INIT)) u_dmem (
    .clk, .addr(dmem_addr), .we(dmem_we & ~is_mmio), .be(dmem_be),
    .wdata(dmem_wdata), .rdata(ram_rdata)
  );

  // ---- MMIO -----------------------------------------------------------------
  logic [63:0] gpio_q;
  always_ff @(posedge clk) begin
    if (!rst_n) gpio_q <= '0;
    else if (dmem_we && is_mmio && dmem_addr[5:3] == 3'd0) begin
      for (int b = 0; b < 8; b++)
        if (dmem_be[b]) gpio_q[8*b +: 8] <= dmem_wdata[8*b +: 8];
    end
  end
  assign gpio_out = gpio_q;

  always_comb begin
    case (dmem_addr[5:3])
      3'd0:    mmio_rdata = gpio_q;
      3'd2:    mmio_rdata = perf_cycles;
      3'd3:    mmio_rdata = perf_instret;
      3'd4:    mmio_rdata = perf_cond_br;
      3'd5:    mmio_rdata = perf_cond_mispred;
      3'd6:    mmio_rdata = perf_ctrl;
      3'd7:    mmio_rdata = perf_ctrl_mispred;
      default: mmio_rdata = '0;
    endcase
  end

  assign dmem_rdata = is_mmio ? mmio_rdata : ram_rdata;
endmodule
