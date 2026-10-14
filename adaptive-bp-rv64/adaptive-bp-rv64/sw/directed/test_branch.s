# All six conditional branches (taken / not-taken, signed / unsigned corners),
# loops, jal / jalr link values, jalr LSB clearing.        PASS: a0 == 0
.include "../common.inc"
    TEST_INIT
    li   t0, 5
    li   t1, 5
    li   t2, -1
    li   t3, 1
    EXPECT_TAKEN beq,  t0, t1
    EXPECT_NOT   beq,  t0, t3
    EXPECT_TAKEN bne,  t0, t3
    EXPECT_NOT   bne,  t0, t1
    EXPECT_TAKEN blt,  t2, t3
    EXPECT_NOT   blt,  t3, t2
    EXPECT_NOT   blt,  t0, t1
    EXPECT_TAKEN bge,  t3, t2
    EXPECT_NOT   bge,  t2, t3
    EXPECT_TAKEN bge,  t0, t1
    EXPECT_TAKEN bltu, t3, t2
    EXPECT_NOT   bltu, t2, t3
    EXPECT_TAKEN bgeu, t2, t3
    EXPECT_NOT   bgeu, t3, t2
    EXPECT_TAKEN bgeu, t0, t1

    # ---- counted loop (backward branch) ----------------------------------
    li   a1, 0
    li   a2, 100
loop1:
    addi a1, a1, 1
    blt  a1, a2, loop1
    CHECK a1, 100

    # ---- nested loops ----------------------------------------------------
    li   a1, 0
    li   s1, 10
outer:
    li   s2, 10
inner:
    addi a1, a1, 1
    addi s2, s2, -1
    bnez s2, inner
    addi s1, s1, -1
    bnez s1, outer
    CHECK a1, 100

    # ---- data dependent forward branches --------------------------------
    li   a1, 0
    li   s1, 64
fwd:
    andi t0, s1, 3
    beqz t0, fwd_skip
    addi a1, a1, 1
fwd_skip:
    addi s1, s1, -1
    bnez s1, fwd
    CHECK a1, 48

    # ---- jal link value ---------------------------------------------------
    jal  a1, after_jal
after_jal:
    la   a2, after_jal
    CHECKR a1, a2

    # ---- jalr: LSB of target is cleared, offset is added, link = next pc ------
    la   t0, jr_target
    addi t0, t0, 1
    jalr x0, 0(t0)
    j    test_fail
jr_target:
    addi t6, t6, 1
    la   t0, jr_target2
    addi t0, t0, -8
    jalr a1, 8(t0)
jalr_link:
    j    test_fail
jr_target2:
    la   a2, jalr_link
    CHECKR a1, a2
    TEST_END
