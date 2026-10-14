// -----------------------------------------------------------------------------
// bp_ras : return address stack (circular, speculative, pointer-checkpointed)
//   * push/pop at fetch (speculative)
//   * on a mispredict the pointer is restored from the checkpoint carried in the
//     metadata and then the *actual* effect of the resolved instruction is applied.
// -----------------------------------------------------------------------------
module bp_ras
  import bp_pkg::*;
#(
  parameter int unsigned DEPTH = 8            // power of two, <= 16
) (
  input  logic                       clk,
  input  logic                       rst_n,
  output logic [XLEN-1:0]            top,
  output logic [$clog2(DEPTH)-1:0]   ptr,
  // speculative operations at fetch
  input  logic                       push,
  input  logic [XLEN-1:0]            push_data,
  input  logic                       pop,
  // recovery at resolve (has priority)
  input  logic                       rec_en,
  input  logic [$clog2(DEPTH)-1:0]   rec_ptr,
  input  logic                       rec_push,
  input  logic [XLEN-1:0]            rec_push_data,
  input  logic                       rec_pop
);
  localparam int unsigned PW = $clog2(DEPTH);
  logic [XLEN-1:0] stack_q [0:DEPTH-1];
  logic [PW-1:0]   ptr_q;

  initial begin
    for (int i = 0; i < DEPTH; i++) stack_q[i] = '0;
  end

  assign ptr = ptr_q;
  assign top = stack_q[ptr_q - PW'(1)];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ptr_q <= '0;
    end else if (rec_en) begin
      if (rec_push) begin
        stack_q[rec_ptr] <= rec_push_data;
        ptr_q            <= rec_ptr + PW'(1);
      end else if (rec_pop) begin
        ptr_q            <= rec_ptr - PW'(1);
      end else begin
        ptr_q            <= rec_ptr;
      end
    end else if (push) begin
      stack_q[ptr_q] <= push_data;
      ptr_q          <= ptr_q + PW'(1);
    end else if (pop) begin
      ptr_q          <= ptr_q - PW'(1);
    end
  end
endmodule
