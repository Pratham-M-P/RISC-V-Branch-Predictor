// -----------------------------------------------------------------------------
// rv64_pkg : constants and control-word types of the RV64I pipeline
// -----------------------------------------------------------------------------
package rv64_pkg;

  localparam int unsigned XLEN = 64;

  // opcodes
  localparam logic [6:0] OPC_LOAD    = 7'b0000011;
  localparam logic [6:0] OPC_MISCMEM = 7'b0001111;
  localparam logic [6:0] OPC_OPIMM   = 7'b0010011;
  localparam logic [6:0] OPC_AUIPC   = 7'b0010111;
  localparam logic [6:0] OPC_OPIMM32 = 7'b0011011;
  localparam logic [6:0] OPC_STORE   = 7'b0100011;
  localparam logic [6:0] OPC_OP      = 7'b0110011;
  localparam logic [6:0] OPC_LUI     = 7'b0110111;
  localparam logic [6:0] OPC_OP32    = 7'b0111011;
  localparam logic [6:0] OPC_BRANCH  = 7'b1100011;
  localparam logic [6:0] OPC_JALR    = 7'b1100111;
  localparam logic [6:0] OPC_JAL     = 7'b1101111;
  localparam logic [6:0] OPC_SYSTEM  = 7'b1110011;

  localparam logic [31:0] INSTR_NOP  = 32'h0000_0013;   // addi x0,x0,0

  typedef enum logic [3:0] {
    ALU_ADD, ALU_SUB, ALU_SLL, ALU_SLT, ALU_SLTU,
    ALU_XOR, ALU_SRL, ALU_SRA, ALU_OR,  ALU_AND
  } alu_op_e;

  typedef struct packed {
    logic      illegal;
    logic      reg_write;
    logic      uses_rs1;
    logic      uses_rs2;
    logic      mem_read;
    logic      mem_write;
    logic      is_branch;
    logic      is_jal;
    logic      is_jalr;
    logic      is_lui;
    logic      is_auipc;
    logic      is_system;     // ecall / ebreak -> halt
    logic      alu_src_imm;
    logic      alu_w;         // 32-bit (W) operation
    alu_op_e   alu_op;
  } ctrl_t;

endpackage
