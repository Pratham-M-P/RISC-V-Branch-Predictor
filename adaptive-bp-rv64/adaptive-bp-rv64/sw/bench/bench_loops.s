# Triple nested counted loops: almost perfectly predictable (loop-exit mispredicts only).
    li   s0, 0
    li   s1, 30
L1: li   s2, 20
L2: li   s3, 10
L3: add  s0, s0, s3
    addi s3, s3, -1
    bnez s3, L3
    addi s2, s2, -1
    bnez s2, L2
    addi s1, s1, -1
    bnez s1, L1
    mv   a0, s0                 # 30*20*55 = 33000
    ecall
