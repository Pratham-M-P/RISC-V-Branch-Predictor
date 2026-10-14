// -----------------------------------------------------------------------------
// rv64_core : 5-stage in-order RV64I pipeline with an adaptive branch predictor
//
//   IF  : PC register, instruction fetch, branch prediction (BTB/tournament/RAS)
//   ID  : decode, register read, load-use hazard detection
//   EX  : ALU, operand forwarding, branch resolution, predictor training
//   MEM : data memory access (byte-lane handling)
//   WB  : register write, commit
//
//   Control hazards: predicted in IF, resolved in EX. A mispredict flushes IF/ID
//   and ID/EX (2-cycle penalty) and redirects the PC. ECALL/EBREAK (or an illegal
//   instruction) stops fetch, squashes younger instructions and raises `halted_o`
//   once it commits.
//
//   Not supported (by design, to keep the focus on the front-end): M/A/F/D/C
//   extensions, CSRs, interrupts, misaligned memory accesses.
// -----------------------------------------------------------------------------
module rv64_core
  import rv64_pkg::*;
  import bp_pkg::bp_meta_t, bp_pkg::bp_update_t;
#(
  parameter logic [XLEN-1:0] RESET_PC       = '0,
  parameter int unsigned     PREDICTOR_TYPE = 3,   // 0 none, 1 bimodal, 2 gshare, 3 tournament
  parameter int unsigned     BIM_IDX_W      = 10,
  parameter int unsigned     GSH_IDX_W      = 10,
  parameter int unsigned     CHO_IDX_W      = 10,
  parameter int unsigned     BTB_IDX_W      = 6,
  parameter int unsigned     BTB_TAG_W      = 16,
  parameter int unsigned     RAS_DEPTH      = 8
) (
  input  logic              clk,
  input  logic              rst_n,

  // instruction memory (asynchronous read)
  output logic [XLEN-1:0]   imem_addr,
  input  logic [31:0]       imem_rdata,

  // data memory (asynchronous read, synchronous write, byte enables)
  output logic [XLEN-1:0]   dmem_addr,
  output logic              dmem_re,
  output logic              dmem_we,
  output logic [7:0]        dmem_be,
  output logic [XLEN-1:0]   dmem_wdata,
  input  logic [XLEN-1:0]   dmem_rdata,

  // commit trace (WB stage)
  output logic              commit_valid,
  output logic [XLEN-1:0]   commit_pc,
  output logic [31:0]       commit_instr,
  output logic [4:0]        commit_rd,        // 0 when nothing is written
  output logic [XLEN-1:0]   commit_data,

  // branch resolution trace (EX stage) -- one pulse per resolved instruction
  output logic              res_valid,
  output logic [XLEN-1:0]   res_pc,
  output logic              res_is_cond,
  output logic              res_is_ctrl,
  output logic              res_taken,
  output logic [XLEN-1:0]   res_target,
  output logic              res_pred_taken,
  output logic [XLEN-1:0]   res_pred_target,
  output logic              res_mispredict,

  // status / performance counters
  output logic              halted_o,
  output logic              illegal_o,
  output logic              stall_o,
  output logic [63:0]       perf_cycles,
  output logic [63:0]       perf_instret,
  output logic [63:0]       perf_cond_br,        // conditional branches resolved
  output logic [63:0]       perf_cond_mispred,   // ... of which mispredicted
  output logic [63:0]       perf_ctrl,           // all control-flow instructions
  output logic [63:0]       perf_ctrl_mispred
);

  // ---------------------------------------------------------------------------
  // Pipeline register types
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic             valid;
    logic [XLEN-1:0]  pc;
    logic [31:0]      instr;
    logic             pred_taken;
    logic [XLEN-1:0]  pred_target;
    bp_meta_t         meta;
  } if_id_t;

  typedef struct packed {
    logic             valid;
    logic [XLEN-1:0]  pc;
    logic [31:0]      instr;
    ctrl_t            ctrl;
    logic [4:0]       rs1, rs2, rd;
    logic [2:0]       funct3;
    logic [XLEN-1:0]  rs1_val, rs2_val, imm;
    logic             pred_taken;
    logic [XLEN-1:0]  pred_target;
    bp_meta_t         meta;
  } id_ex_t;

  typedef struct packed {
    logic             valid;
    logic [XLEN-1:0]  pc;
    logic [31:0]      instr;
    ctrl_t            ctrl;
    logic [4:0]       rd;
    logic [2:0]       funct3;
    logic [XLEN-1:0]  result;       // ALU result / link address / memory address
    logic [XLEN-1:0]  store_data;
  } ex_mem_t;

  typedef struct packed {
    logic             valid;
    logic [XLEN-1:0]  pc;
    logic [31:0]      instr;
    ctrl_t            ctrl;
    logic [4:0]       rd;
    logic [XLEN-1:0]  result;
  } mem_wb_t;

  if_id_t  if_id;
  id_ex_t  id_ex;
  ex_mem_t ex_mem;
  mem_wb_t mem_wb;

  // ---------------------------------------------------------------------------
  // Global control
  // ---------------------------------------------------------------------------
  logic [XLEN-1:0] pc_q;
  logic            halt_fetch_q;     // fetch stopped after ECALL/EBREAK/illegal reached EX
  logic            halted_q;
  logic            illegal_q;

  logic            stall;            // load-use hazard
  logic            ex_mispredict;
  logic [XLEN-1:0] ex_redirect_pc;
  logic            ex_halt;
  wire             flush  = ex_mispredict | ex_halt;
  wire             if_valid = ~halt_fetch_q;
  wire             if_adv   = if_valid & ~stall & ~flush;

  assign stall_o = stall;

  // ---------------------------------------------------------------------------
  // IF stage
  // ---------------------------------------------------------------------------
  logic             if_pred_taken;
  logic [XLEN-1:0]  if_pred_target;
  bp_meta_t         if_meta;
  bp_update_t       bp_upd;

  assign imem_addr = pc_q;

  branch_predictor #(
    .PREDICTOR_TYPE (PREDICTOR_TYPE),
    .BIM_IDX_W      (BIM_IDX_W),
    .GSH_IDX_W      (GSH_IDX_W),
    .CHO_IDX_W      (CHO_IDX_W),
    .BTB_IDX_W      (BTB_IDX_W),
    .BTB_TAG_W      (BTB_TAG_W),
    .RAS_DEPTH      (RAS_DEPTH)
  ) u_bp (
    .clk           (clk),
    .rst_n         (rst_n),
    .pc_i          (pc_q),
    .fetch_adv_i   (if_adv),
    .pred_taken_o  (if_pred_taken),
    .pred_target_o (if_pred_target),
    .pred_meta_o   (if_meta),
    .upd_i         (bp_upd)
  );

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pc_q <= RESET_PC;
    end else if (ex_mispredict) begin
      pc_q <= ex_redirect_pc;
    end else if (if_adv) begin
      pc_q <= if_pred_taken ? if_pred_target : pc_q + XLEN'(4);
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n || flush) begin
      if_id <= '0;
    end else if (!stall) begin
      if_id.valid       <= if_valid;
      if_id.pc          <= pc_q;
      if_id.instr       <= imem_rdata;
      if_id.pred_taken  <= if_pred_taken;
      if_id.pred_target <= if_pred_target;
      if_id.meta        <= if_meta;
    end
  end

  // ---------------------------------------------------------------------------
  // ID stage
  // ---------------------------------------------------------------------------
  ctrl_t           id_ctrl_raw, id_ctrl;
  logic [XLEN-1:0] id_imm;
  logic [XLEN-1:0] id_rs1_val, id_rs2_val;
  wire  [4:0]      id_rs1 = if_id.instr[19:15];
  wire  [4:0]      id_rs2 = if_id.instr[24:20];
  wire  [4:0]      id_rd  = if_id.instr[11:7];

  rv64_decoder u_dec (.instr(if_id.instr), .ctrl(id_ctrl_raw), .imm(id_imm));

  // an illegal instruction is neutralised; it halts the machine when it reaches EX
  always_comb begin
    id_ctrl = id_ctrl_raw;
    if (id_ctrl_raw.illegal) begin
      id_ctrl.reg_write = 1'b0;
      id_ctrl.mem_read  = 1'b0;
      id_ctrl.mem_write = 1'b0;
      id_ctrl.is_branch = 1'b0;
      id_ctrl.is_jal    = 1'b0;
      id_ctrl.is_jalr   = 1'b0;
      id_ctrl.is_system = 1'b1;
    end
  end

  logic [XLEN-1:0] wb_data;
  logic            wb_we;

  rv64_regfile u_rf (
    .clk      (clk),
    .rs1_addr (id_rs1), .rs2_addr (id_rs2),
    .rs1_data (id_rs1_val), .rs2_data (id_rs2_val),
    .we       (wb_we), .wr_addr (mem_wb.rd), .wr_data (wb_data)
  );

  // load-use hazard: producer is a load in EX, consumer is in ID
  assign stall = if_id.valid & id_ex.valid & id_ex.ctrl.mem_read & (id_ex.rd != 5'd0) &
                 ((id_ctrl.uses_rs1 & (id_ex.rd == id_rs1)) |
                  (id_ctrl.uses_rs2 & (id_ex.rd == id_rs2)));

  always_ff @(posedge clk) begin
    if (!rst_n || flush || stall) begin
      id_ex <= '0;
    end else begin
      id_ex.valid       <= if_id.valid;
      id_ex.pc          <= if_id.pc;
      id_ex.instr       <= if_id.instr;
      id_ex.ctrl        <= id_ctrl;
      id_ex.rs1         <= id_rs1;
      id_ex.rs2         <= id_rs2;
      id_ex.rd          <= id_rd;
      id_ex.funct3      <= if_id.instr[14:12];
      id_ex.rs1_val     <= id_rs1_val;
      id_ex.rs2_val     <= id_rs2_val;
      id_ex.imm         <= id_imm;
      id_ex.pred_taken  <= if_id.pred_taken;
      id_ex.pred_target <= if_id.pred_target;
      id_ex.meta        <= if_id.meta;
    end
  end

  // ---------------------------------------------------------------------------
  // EX stage
  // ---------------------------------------------------------------------------
  logic [XLEN-1:0] fwd_a, fwd_b;

  always_comb begin
    fwd_a = id_ex.rs1_val;
    fwd_b = id_ex.rs2_val;
    if (mem_wb.valid && mem_wb.ctrl.reg_write && mem_wb.rd != 5'd0) begin
      if (mem_wb.rd == id_ex.rs1) fwd_a = wb_data;
      if (mem_wb.rd == id_ex.rs2) fwd_b = wb_data;
    end
    if (ex_mem.valid && ex_mem.ctrl.reg_write && ex_mem.rd != 5'd0) begin
      if (ex_mem.rd == id_ex.rs1) fwd_a = ex_mem.result;
      if (ex_mem.rd == id_ex.rs2) fwd_b = ex_mem.result;
    end
  end

  logic [XLEN-1:0] alu_a, alu_b, alu_y;
  assign alu_a = id_ex.ctrl.is_auipc ? id_ex.pc :
                 id_ex.ctrl.is_lui   ? '0       : fwd_a;
  assign alu_b = id_ex.ctrl.alu_src_imm ? id_ex.imm : fwd_b;

  rv64_alu u_alu (
    .op(id_ex.ctrl.alu_op), .is_w(id_ex.ctrl.alu_w),
    .a(alu_a), .b(alu_b), .y(alu_y)
  );

  wire [XLEN-1:0] pc_plus4 = id_ex.pc + XLEN'(4);
  wire [XLEN-1:0] ex_result = (id_ex.ctrl.is_jal | id_ex.ctrl.is_jalr) ? pc_plus4 : alu_y;

  // branch comparator
  logic br_cmp;
  always_comb begin
    case (id_ex.funct3)
      3'b000:  br_cmp = (fwd_a == fwd_b);
      3'b001:  br_cmp = (fwd_a != fwd_b);
      3'b100:  br_cmp = ($signed(fwd_a) <  $signed(fwd_b));
      3'b101:  br_cmp = ($signed(fwd_a) >= $signed(fwd_b));
      3'b110:  br_cmp = (fwd_a <  fwd_b);
      3'b111:  br_cmp = (fwd_a >= fwd_b);
      default: br_cmp = 1'b0;
    endcase
  end

  wire            ex_is_ctrl = id_ex.ctrl.is_branch | id_ex.ctrl.is_jal | id_ex.ctrl.is_jalr;
  wire            ex_taken   = id_ex.ctrl.is_jal | id_ex.ctrl.is_jalr | (id_ex.ctrl.is_branch & br_cmp);
  wire [XLEN-1:0] ex_target  = id_ex.ctrl.is_jalr ? ((fwd_a + id_ex.imm) & ~XLEN'(1))
                                                  : (id_ex.pc + id_ex.imm);
  wire [XLEN-1:0] ex_actual_next = ex_taken ? ex_target : pc_plus4;
  wire [XLEN-1:0] ex_pred_next   = id_ex.pred_taken ? id_ex.pred_target : pc_plus4;

  // A mispredict is *any* disagreement between the fetched next-PC and the real
  // next-PC. This also catches BTB aliasing (a "taken" prediction on a non-branch).
  assign ex_mispredict  = id_ex.valid & (ex_actual_next != ex_pred_next);
  assign ex_redirect_pc = ex_actual_next;
  assign ex_halt        = id_ex.valid & id_ex.ctrl.is_system;

  wire id_rd_is_link  = (id_ex.rd == 5'd1) | (id_ex.rd == 5'd5);
  wire id_rs1_is_link = (id_ex.rs1 == 5'd1) | (id_ex.rs1 == 5'd5);

  always_comb begin
    bp_upd            = '0;
    bp_upd.valid      = id_ex.valid;
    bp_upd.pc         = id_ex.pc;
    bp_upd.is_cond    = id_ex.ctrl.is_branch;
    bp_upd.is_jal     = id_ex.ctrl.is_jal;
    bp_upd.is_jalr    = id_ex.ctrl.is_jalr;
    bp_upd.is_call    = (id_ex.ctrl.is_jal | id_ex.ctrl.is_jalr) & id_rd_is_link;
    bp_upd.is_ret     = id_ex.ctrl.is_jalr & (id_ex.rd == 5'd0) & id_rs1_is_link;
    bp_upd.taken      = ex_taken;
    bp_upd.target     = ex_target;
    bp_upd.mispredict = ex_mispredict;
    bp_upd.meta       = id_ex.meta;
  end

  // resolution trace for verification / statistics
  assign res_valid       = id_ex.valid & ex_is_ctrl;
  assign res_pc          = id_ex.pc;
  assign res_is_cond     = id_ex.ctrl.is_branch;
  assign res_is_ctrl     = ex_is_ctrl;
  assign res_taken       = ex_taken;
  assign res_target      = ex_target;
  assign res_pred_taken  = id_ex.pred_taken;
  assign res_pred_target = id_ex.pred_target;
  assign res_mispredict  = ex_mispredict;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ex_mem <= '0;
    end else begin
      ex_mem.valid      <= id_ex.valid;
      ex_mem.pc         <= id_ex.pc;
      ex_mem.instr      <= id_ex.instr;
      ex_mem.ctrl       <= id_ex.ctrl;
      ex_mem.rd         <= id_ex.rd;
      ex_mem.funct3     <= id_ex.funct3;
      ex_mem.result     <= ex_result;
      ex_mem.store_data <= fwd_b;
    end
  end

  // ---------------------------------------------------------------------------
  // MEM stage
  // ---------------------------------------------------------------------------
  wire [2:0] mem_off = ex_mem.result[2:0];

  assign dmem_addr = ex_mem.result;
  assign dmem_re   = ex_mem.valid & ex_mem.ctrl.mem_read;
  assign dmem_we   = ex_mem.valid & ex_mem.ctrl.mem_write;

  always_comb begin
    dmem_be    = 8'h00;
    dmem_wdata = ex_mem.store_data;
    case (ex_mem.funct3[1:0])
      2'b00:   begin dmem_be = 8'h01 << mem_off; dmem_wdata = {8{ex_mem.store_data[7:0]}};  end
      2'b01:   begin dmem_be = 8'h03 << mem_off; dmem_wdata = {4{ex_mem.store_data[15:0]}}; end
      2'b10:   begin dmem_be = 8'h0F << mem_off; dmem_wdata = {2{ex_mem.store_data[31:0]}}; end
      default: begin dmem_be = 8'hFF;            dmem_wdata = ex_mem.store_data;            end
    endcase
  end

  logic [XLEN-1:0] load_shifted, load_data;
  assign load_shifted = dmem_rdata >> {mem_off, 3'b000};

  always_comb begin
    case (ex_mem.funct3)
      3'b000:  load_data = {{56{load_shifted[7]}},  load_shifted[7:0]};    // LB
      3'b001:  load_data = {{48{load_shifted[15]}}, load_shifted[15:0]};   // LH
      3'b010:  load_data = {{32{load_shifted[31]}}, load_shifted[31:0]};   // LW
      3'b011:  load_data = load_shifted;                                   // LD
      3'b100:  load_data = {56'b0, load_shifted[7:0]};                     // LBU
      3'b101:  load_data = {48'b0, load_shifted[15:0]};                    // LHU
      3'b110:  load_data = {32'b0, load_shifted[31:0]};                    // LWU
      default: load_data = load_shifted;
    endcase
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      mem_wb <= '0;
    end else begin
      mem_wb.valid  <= ex_mem.valid;
      mem_wb.pc     <= ex_mem.pc;
      mem_wb.instr  <= ex_mem.instr;
      mem_wb.ctrl   <= ex_mem.ctrl;
      mem_wb.rd     <= ex_mem.rd;
      mem_wb.result <= ex_mem.ctrl.mem_read ? load_data : ex_mem.result;
    end
  end

  // ---------------------------------------------------------------------------
  // WB stage / commit
  // ---------------------------------------------------------------------------
  assign wb_data = mem_wb.result;
  wire   wb_live = mem_wb.valid & ~halted_q;
  assign wb_we   = wb_live & mem_wb.ctrl.reg_write & (mem_wb.rd != 5'd0);

  assign commit_valid = wb_live;
  assign commit_pc    = mem_wb.pc;
  assign commit_instr = mem_wb.instr;
  assign commit_rd    = wb_we ? mem_wb.rd : 5'd0;
  assign commit_data  = wb_we ? mem_wb.result : '0;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      halt_fetch_q <= 1'b0;
      halted_q     <= 1'b0;
      illegal_q    <= 1'b0;
    end else begin
      if (ex_halt) halt_fetch_q <= 1'b1;
      if (wb_live && mem_wb.ctrl.is_system) begin
        halted_q  <= 1'b1;
        illegal_q <= (mem_wb.instr[6:0] != OPC_SYSTEM);
      end
    end
  end

  assign halted_o  = halted_q;
  assign illegal_o = illegal_q;

  // ---------------------------------------------------------------------------
  // Performance counters
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      perf_cycles       <= '0;
      perf_instret      <= '0;
      perf_cond_br      <= '0;
      perf_cond_mispred <= '0;
      perf_ctrl         <= '0;
      perf_ctrl_mispred <= '0;
    end else begin
      if (!halted_q) perf_cycles <= perf_cycles + 64'd1;
      if (wb_live)   perf_instret <= perf_instret + 64'd1;
      if (id_ex.valid && !halted_q) begin
        if (id_ex.ctrl.is_branch) begin
          perf_cond_br <= perf_cond_br + 64'd1;
          if (ex_mispredict) perf_cond_mispred <= perf_cond_mispred + 64'd1;
        end
        if (ex_is_ctrl) begin
          perf_ctrl <= perf_ctrl + 64'd1;
          if (ex_mispredict) perf_ctrl_mispred <= perf_ctrl_mispred + 64'd1;
        end
      end
    end
  end

endmodule
