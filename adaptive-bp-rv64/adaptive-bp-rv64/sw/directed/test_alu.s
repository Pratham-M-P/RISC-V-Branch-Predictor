# ALU / immediate / W-form / LUI / AUIPC checks.   PASS: a0 == 0
.include "../common.inc"
    TEST_INIT
    li   t0, 100
    li   t1, 7
    add  a1, t0, t1
    CHECK a1, 107
    sub  a1, t0, t1
    CHECK a1, 93
    sll  a1, t0, t1
    CHECK a1, 12800
    li   t2, -1
    slt  a1, t2, t1
    CHECK a1, 1
    sltu a1, t2, t1
    CHECK a1, 0
    xor  a1, t0, t1
    CHECK a1, 99
    or   a1, t0, t1
    CHECK a1, 103
    and  a1, t0, t1
    CHECK a1, 4
    srl  a1, t2, t1
    CHECK a1, 0x01FFFFFFFFFFFFFF
    sra  a1, t2, t1
    CHECK a1, -1

    # ---- immediates -------------------------------------------------------
    addi a1, t0, -101
    CHECK a1, -1
    addi a1, x0, 2047
    CHECK a1, 2047
    addi a1, x0, -2048
    CHECK a1, -2048
    slti a1, t2, 0
    CHECK a1, 1
    sltiu a1, t2, -1
    CHECK a1, 0
    sltiu a1, x0, -1
    CHECK a1, 1
    xori a1, t0, -1
    CHECK a1, -101
    ori  a1, t0, 0x0f
    CHECK a1, 111
    andi a1, t0, 0x0f
    CHECK a1, 4
    slli a1, t0, 40
    CHECK a1, 109951162777600
    srli a1, t2, 60
    CHECK a1, 15
    srai a1, t2, 60
    CHECK a1, -1
    li   t3, -16
    srai a1, t3, 2
    CHECK a1, -4

    # ---- RV64 W forms -----------------------------------------------------
    li   t0, 0xFFFFFFFF
    addw a1, t0, x0
    CHECK a1, -1
    li   t0, 0x7fffffff
    addiw a1, t0, 1
    CHECK a1, -2147483648
    li   t0, 1
    slliw a1, t0, 31
    CHECK a1, -2147483648
    li   t0, -1
    srliw a1, t0, 1
    CHECK a1, 2147483647
    li   t0, -8
    sraiw a1, t0, 1
    CHECK a1, -4
    li   t1, 1
    sraw a1, t0, t1
    CHECK a1, -4
    srlw a1, t0, t1
    CHECK a1, 2147483644
    sllw a1, t0, t1
    CHECK a1, -16
    li   t0, 3
    li   t1, 5
    subw a1, t0, t1
    CHECK a1, -2
    li   t0, 0x100000001
    slliw a1, t0, 1
    CHECK a1, 2
    addiw a1, t0, 0
    CHECK a1, 1

    # ---- LUI / AUIPC / li -------------------------------------------------
    lui  a1, 0x12345
    CHECK a1, 0x12345000
    lui  a1, 0x80000
    CHECK a1, -2147483648
    auipc a1, 1
    auipc a2, 0
    sub  a3, a1, a2
    CHECK a3, 4092
    li   a1, 0x123456789abcdef0
    li   a2, 0x12345678
    slli a2, a2, 32
    li   a3, 0x9abcdef0
    add  a2, a2, a3
    CHECKR a1, a2

    # ---- x0 is hard-wired -------------------------------------------------
    addi x0, x0, 5
    add  a1, x0, x0
    CHECK a1, 0
    TEST_END
