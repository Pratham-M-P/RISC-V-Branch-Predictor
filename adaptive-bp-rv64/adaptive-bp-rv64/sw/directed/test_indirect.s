# Indirect jumps cycling through four targets (BTB target prediction is wrong 3/4 of the time)
# and a computed-goto dispatch loop.
.include "../common.inc"
.data
jtab:   .dword tgt0, tgt1, tgt2, tgt3
.text
    TEST_INIT
    la   s0, jtab
    li   s1, 0                   # accumulator
    li   s2, 0                   # iteration
    li   s3, 64
disp:
    andi t0, s2, 3
    slli t0, t0, 3
    add  t0, t0, s0
    ld   t1, 0(t0)
    jalr x0, 0(t1)
tgt0:
    addi s1, s1, 1
    j    join
tgt1:
    addi s1, s1, 10
    j    join
tgt2:
    addi s1, s1, 100
    j    join
tgt3:
    addi s1, s1, 1000
join:
    addi s2, s2, 1
    blt  s2, s3, disp
    CHECK s1, 17776              # 16 * 1111
    TEST_END
