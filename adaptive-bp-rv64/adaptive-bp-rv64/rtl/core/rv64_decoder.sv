// -----------------------------------------------------------------------------
// rv64_decoder : RV64I instruction decoder (no M/A/F/D, no CSRs, no FENCE.I)
// -----------------------------------------------------------------------------
module rv64_decoder
  import rv64_pkg::*;
(
  input  logic [31:0]     instr,
  output ctrl_t           ctrl,
  output logic [XLEN-1:0] imm
);
  wire [6:0] opcode = instr[6:0];
  wire [2:0] funct3 = instr[14:12];
  wire       f7_5   = instr[30];

  // immediates
  wire [XLEN-1:0] imm_i = {{52{instr[31]}}, instr[31:20]};
  wire [XLEN-1:0] imm_s = {{52{instr[31]}}, instr[31:25], instr[11:7]};
  wire [XLEN-1:0] imm_b = {{51{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
  wire [XLEN-1:0] imm_u = {{32{instr[31]}}, instr[31:12], 12'b0};
  wire [XLEN-1:0] imm_j = {{43{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};

  always_comb begin
    ctrl = '0;
    imm  = imm_i;
    ctrl.alu_op = ALU_ADD;

    case (opcode)
      OPC_LUI: begin
        ctrl.is_lui = 1'b1; ctrl.reg_write = 1'b1; ctrl.alu_src_imm = 1'b1; imm = imm_u;
      end
      OPC_AUIPC: begin
        ctrl.is_auipc = 1'b1; ctrl.reg_write = 1'b1; ctrl.alu_src_imm = 1'b1; imm = imm_u;
      end
      OPC_JAL: begin
        ctrl.is_jal = 1'b1; ctrl.reg_write = 1'b1; imm = imm_j;
      end
      OPC_JALR: begin
        ctrl.is_jalr = 1'b1; ctrl.reg_write = 1'b1; ctrl.uses_rs1 = 1'b1; imm = imm_i;
        if (funct3 != 3'b000) ctrl.illegal = 1'b1;
      end
      OPC_BRANCH: begin
        ctrl.is_branch = 1'b1; ctrl.uses_rs1 = 1'b1; ctrl.uses_rs2 = 1'b1; imm = imm_b;
        if (funct3 == 3'b010 || funct3 == 3'b011) ctrl.illegal = 1'b1;
      end
      OPC_LOAD: begin
        ctrl.mem_read = 1'b1; ctrl.reg_write = 1'b1; ctrl.uses_rs1 = 1'b1;
        ctrl.alu_src_imm = 1'b1; imm = imm_i;
        if (funct3 == 3'b111) ctrl.illegal = 1'b1;
      end
      OPC_STORE: begin
        ctrl.mem_write = 1'b1; ctrl.uses_rs1 = 1'b1; ctrl.uses_rs2 = 1'b1;
        ctrl.alu_src_imm = 1'b1; imm = imm_s;
        if (funct3 > 3'b011) ctrl.illegal = 1'b1;
      end
      OPC_OPIMM, OPC_OPIMM32: begin
        ctrl.reg_write = 1'b1; ctrl.uses_rs1 = 1'b1; ctrl.alu_src_imm = 1'b1; imm = imm_i;
        ctrl.alu_w = (opcode == OPC_OPIMM32);
        case (funct3)
          3'b000: ctrl.alu_op = ALU_ADD;
          3'b001: ctrl.alu_op = ALU_SLL;
          3'b010: ctrl.alu_op = ALU_SLT;
          3'b011: ctrl.alu_op = ALU_SLTU;
          3'b100: ctrl.alu_op = ALU_XOR;
          3'b101: ctrl.alu_op = f7_5 ? ALU_SRA : ALU_SRL;
          3'b110: ctrl.alu_op = ALU_OR;
          3'b111: ctrl.alu_op = ALU_AND;
        endcase
        if (opcode == OPC_OPIMM32 && !(funct3 == 3'b000 || funct3 == 3'b001 || funct3 == 3'b101))
          ctrl.illegal = 1'b1;
      end
      OPC_OP, OPC_OP32: begin
        ctrl.reg_write = 1'b1; ctrl.uses_rs1 = 1'b1; ctrl.uses_rs2 = 1'b1;
        ctrl.alu_w = (opcode == OPC_OP32);
        case (funct3)
          3'b000: ctrl.alu_op = f7_5 ? ALU_SUB : ALU_ADD;
          3'b001: ctrl.alu_op = ALU_SLL;
          3'b010: ctrl.alu_op = ALU_SLT;
          3'b011: ctrl.alu_op = ALU_SLTU;
          3'b100: ctrl.alu_op = ALU_XOR;
          3'b101: ctrl.alu_op = f7_5 ? ALU_SRA : ALU_SRL;
          3'b110: ctrl.alu_op = ALU_OR;
          3'b111: ctrl.alu_op = ALU_AND;
        endcase
        if (instr[31:25] != 7'b0000000 && instr[31:25] != 7'b0100000) ctrl.illegal = 1'b1; // M-ext unsupported
        if (opcode == OPC_OP32 && !(funct3 == 3'b000 || funct3 == 3'b001 || funct3 == 3'b101))
          ctrl.illegal = 1'b1;
      end
      OPC_MISCMEM: begin
        // FENCE: architectural no-op in this single-hart in-order core
      end
      OPC_SYSTEM: begin
        ctrl.is_system = 1'b1;   // ecall / ebreak: halt the simulation / FPGA demo
      end
      default: ctrl.illegal = 1'b1;
    endcase
  end
endmodule
