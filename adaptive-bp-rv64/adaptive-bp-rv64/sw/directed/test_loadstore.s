# Loads / stores of every width, sign / zero extension, byte lanes, MMIO GPIO.
.include "../common.inc"
.data
buf:    .dword 0x8877665544332211, 0xFFEEDDCCBBAA9988
        .zero  32
.text
    TEST_INIT
    la   s0, buf
    ld   a1, 0(s0)
    CHECK a1, 0x8877665544332211
    lb   a1, 0(s0)
    CHECK a1, 0x11
    lb   a1, 3(s0)
    CHECK a1, 0x44
    lb   a1, 7(s0)
    CHECK a1, -120
    lbu  a1, 7(s0)
    CHECK a1, 136
    lh   a1, 0(s0)
    CHECK a1, 0x2211
    lh   a1, 2(s0)
    CHECK a1, 0x4433
    lh   a1, 6(s0)
    CHECK a1, -30601
    lhu  a1, 6(s0)
    CHECK a1, 34935
    lw   a1, 0(s0)
    CHECK a1, 0x44332211
    lw   a1, 4(s0)
    CHECK a1, -2005440939
    lwu  a1, 4(s0)
    CHECK a1, 2289526357
    ld   a1, 8(s0)
    CHECK a1, 0xFFEEDDCCBBAA9988
    lb   a1, 15(s0)
    CHECK a1, -1
    lbu  a1, 15(s0)
    CHECK a1, 255

    # ---- stores merge into the right byte lanes ---------------------------
    sd   x0, 16(s0)
    li   t0, 0xAB
    sb   t0, 19(s0)
    ld   a1, 16(s0)
    CHECK a1, 0xAB000000
    li   t0, 0xCDEF
    sh   t0, 22(s0)
    ld   a1, 16(s0)
    CHECK a1, 0xCDEF0000AB000000
    li   t0, 0x12345678
    sw   t0, 20(s0)
    ld   a1, 16(s0)
    CHECK a1, 0x12345678AB000000
    sd   t0, 24(s0)
    ld   a1, 24(s0)
    CHECK a1, 0x12345678
    li   t0, -2
    sd   t0, 32(s0)
    sw   x0, 36(s0)
    ld   a1, 32(s0)
    CHECK a1, 0xFFFFFFFE
    sb   x0, 32(s0)
    lbu  a1, 32(s0)
    CHECK a1, 0

    # ---- memory-mapped GPIO ------------------------------------------------
    li   t0, 0x80000000
    li   a1, 0x55
    sd   a1, 0(t0)
    ld   a2, 0(t0)
    CHECKR a1, a2
    li   a1, 0xAA
    sb   a1, 1(t0)
    ld   a2, 0(t0)
    CHECK a2, 0xAA55
    TEST_END
