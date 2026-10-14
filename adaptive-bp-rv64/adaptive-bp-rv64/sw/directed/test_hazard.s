# Data-hazard stress: forwarding from EX/MEM and MEM/WB, WB->ID bypass, load-use
# stalls (ALU, store data, branch operand, jalr target), youngest-writer-wins.
.include "../common.inc"
.data
pad:    .dword 0
tbl:    .dword 11, 22, 33, 0
ptr:    .dword 0
.text
    TEST_INIT
    # back-to-back dependent chain
    li   t0, 1
    add  t1, t0, t0
    add  t2, t1, t1
    add  t3, t2, t2
    add  a1, t3, t3
    CHECK a1, 16
    # both operands from different producers
    li   t0, 3
    li   t1, 4
    add  t2, t0, t1
    sub  a1, t2, t0
    CHECK a1, 4
    # youngest writer wins
    addi t0, x0, 1
    addi t0, x0, 2
    add  a1, t0, t0
    CHECK a1, 4
    # x0 never forwards
    addi x0, x0, 7
    add  a1, x0, x0
    CHECK a1, 0
    # 3 apart (WB -> ID bypass in the register file)
    li   t0, 9
    nop
    nop
    add  a1, t0, t0
    CHECK a1, 18

    # ---- load-use ----------------------------------------------------------
    la   s0, tbl
    ld   t0, 0(s0)
    add  a1, t0, t0              # immediate use of load result
    CHECK a1, 22
    ld   t0, 8(s0)
    nop
    add  a1, t0, t0              # one instruction gap
    CHECK a1, 44
    ld   t0, 16(s0)
    sd   t0, 24(s0)              # load result used as store data
    ld   a1, 24(s0)
    CHECK a1, 33
    ld   t0, 0(s0)
    sd   t0, 24(s0)
    ld   t1, 24(s0)              # load -> store -> load
    addi a1, t1, 1
    CHECK a1, 12
    # load result is a load address
    la   t0, tbl
    la   t2, ptr
    sd   t0, 0(t2)
    ld   t1, 0(t2)               # t1 = &tbl
    ld   a1, 8(t1)               # dependent load: needs stall
    CHECK a1, 22
    # load result feeds a branch
    ld   t0, 0(s0)
    la   t1, tbl
    ld   t2, 16(t1)
    li   t3, 33
    beq  t2, t3, lu_ok
    j    test_fail
lu_ok:
    addi t6, t6, 1
    # load result feeds a jalr
    la   t0, jtarget
    la   t1, ptr
    sd   t0, 0(t1)
    ld   t2, 0(t1)
    jalr x0, 0(t2)
    j    test_fail
jtarget:
    addi t6, t6, 1
    # branch operands forwarded from the immediately preceding instruction
    li   t0, 5
    addi t0, t0, 1
    li   t1, 6
    EXPECT_TAKEN beq, t0, t1
    # jalr target forwarded from the previous instruction
    la   t4, jt2
    jalr x0, 0(t4)
    j    test_fail
jt2:
    TEST_END
