# Mixed workload: one history-correlated branch (period-4 pattern), one noisy but biased
# branch (random, taken 1/8), loop-closing branches and a leaf call -- the situation the
# adaptive (tournament) predictor is built for: each static branch picks the better component.
    li   sp, 0x3f00
    li   s0, 0
    li   s1, 5000
    li   s2, 0x1234567812345678
    li   s3, 0
loop:
    andi t0, s3, 3
    bnez t0, pat_skip             # T N N N pattern  (gshare: perfect, bimodal: 25% miss)
    addi s0, s0, 1
pat_skip:
    slli t1, s2, 13               # xorshift64
    xor  s2, s2, t1
    srli t1, s2, 7
    xor  s2, s2, t1
    slli t1, s2, 17
    xor  s2, s2, t1
    srli t1, s2, 40
    andi t1, t1, 7
    bnez t1, noisy_skip           # noisy: not-taken 1/8 (bimodal: ~12% miss, gshare dilutes)
    call leaf
noisy_skip:
    addi s3, s3, 1
    addi s1, s1, -1
    bnez s1, loop
    mv   a0, s0
    ecall
leaf:
    addi s0, s0, 7
    ret
