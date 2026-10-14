# Pseudo-random data driven branches:
#   branch R : ~50% taken, unpredictable for every predictor (floor on accuracy)
#   branch B : taken 15/16 of the time, strongly biased  (bimodal friendly)
    li   s0, 0
    li   s1, 5000
    li   s2, 0x2545F4914F6CDD1D       # xorshift64 state
loop:
    slli t0, s2, 13
    xor  s2, s2, t0
    srli t0, s2, 7
    xor  s2, s2, t0
    slli t0, s2, 17
    xor  s2, s2, t0
    srli t0, s2, 20
    andi t1, t0, 1
    beqz t1, rnd_skip           # R: random
    addi s0, s0, 1
rnd_skip:
    srli t0, s2, 32
    andi t1, t0, 15
    beqz t1, bias_skip          # B: not-taken 1/16
    addi s0, s0, 2
bias_skip:
    addi s1, s1, -1
    bnez s1, loop
    mv   a0, s0
    ecall
