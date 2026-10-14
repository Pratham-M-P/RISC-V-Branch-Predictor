# ---------------------------------------------------------------------------
# common.inc : helpers for self-checking tests
#   t6 = running check number, t5 = scratch.  a0 == 0 at ECALL means PASS,
#   otherwise a0 holds the number of the first failing check.
# ---------------------------------------------------------------------------
.macro CHECK reg, val
  li   t5, \val
  addi t6, t6, 1
  bne  \reg, t5, test_fail
.endm

.macro CHECKR r1, r2
  addi t6, t6, 1
  bne  \r1, \r2, test_fail
.endm

.macro EXPECT_TAKEN insn, ra, rb
  addi t6, t6, 1
  \insn \ra, \rb, taken_\@
  j    test_fail
taken_\@:
.endm

.macro EXPECT_NOT insn, ra, rb
  addi t6, t6, 1
  \insn \ra, \rb, test_fail
.endm

.macro TEST_INIT
  li   t6, 0
  li   sp, 0x3f00
.endm

.macro TEST_END
  li   a0, 0
  ecall
test_fail:
  mv   a0, t6
  ecall
.endm
