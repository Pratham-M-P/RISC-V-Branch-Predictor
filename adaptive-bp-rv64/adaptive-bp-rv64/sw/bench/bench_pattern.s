# Branches whose outcome follows a repeating bit pattern.  Without history a bimodal
# counter hovers around the majority outcome; a history-based predictor (gshare)
# learns the pattern exactly.
    li   s0, 0                  # accumulator
    li   s1, 6000               # iterations
    li   s2, 0xB38B             # 16-bit pattern A (period 16)
    li   s3, 0x0F0F             # 16-bit pattern B (period 16)
loop:
    andi t0, s2, 1
    beqz t0, skipA              # data-dependent on pattern A
    addi s0, s0, 3
skipA:
    andi t0, s3, 1
    bnez t0, skipB              # data-dependent on pattern B
    addi s0, s0, 5
skipB:
    srli t1, s2, 1              # rotate A right by 1 (16-bit)
    andi t2, s2, 1
    slli t2, t2, 15
    or   s2, t1, t2
    srli t1, s3, 3              # rotate B right by 3 (16-bit, period 16 as 3 is odd)
    andi t2, s3, 7
    slli t2, t2, 13
    or   s3, t1, t2
    addi s1, s1, -1
    bnez s1, loop
    mv   a0, s0
    ecall
