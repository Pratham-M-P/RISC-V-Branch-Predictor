// -----------------------------------------------------------------------------
// rv64_alu : 64-bit ALU with RV64 "W" (32-bit, sign-extended) variants
// -----------------------------------------------------------------------------
module rv64_alu
  import rv64_pkg::*;
(
  input  alu_op_e         op,
  input  logic            is_w,
  input  logic [XLEN-1:0] a,
  input  logic [XLEN-1:0] b,
  output logic [XLEN-1:0] y
);
  logic [XLEN-1:0]   r64;
  logic [31:0]       r32;
  logic signed [63:0] sa, sb;
  logic signed [31:0] sa32;

  always_comb begin
    sa   = a;
    sb   = b;
    sa32 = a[31:0];
    r64  = '0;
    r32  = '0;
    case (op)
      ALU_ADD:  begin r64 = a + b;                      r32 = a[31:0] + b[31:0];   end
      ALU_SUB:  begin r64 = a - b;                      r32 = a[31:0] - b[31:0];   end
      ALU_SLL:  begin r64 = a << b[5:0];                r32 = a[31:0] << b[4:0];   end
      ALU_SLT:  begin r64 = {63'b0, (sa < sb)};         end
      ALU_SLTU: begin r64 = {63'b0, (a < b)};           end
      ALU_XOR:  begin r64 = a ^ b;                      end
      ALU_SRL:  begin r64 = a >> b[5:0];                r32 = a[31:0] >> b[4:0];   end
      ALU_SRA:  begin r64 = XLEN'(sa >>> b[5:0]);       r32 = 32'(sa32 >>> b[4:0]); end
      ALU_OR:   begin r64 = a | b;                      end
      ALU_AND:  begin r64 = a & b;                      end
      default:  begin r64 = '0;                         end
    endcase
    y = is_w ? {{32{r32[31]}}, r32} : r64;
  end
endmodule
