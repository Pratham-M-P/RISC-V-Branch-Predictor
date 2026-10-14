# FPGA demo: run a branchy workload, then read the hardware performance counters through
# MMIO, compute the conditional-branch prediction accuracy (percent) and publish it.
#
#   GPIO (0x8000_0000) bits [7:0]  = accuracy in percent
#                      bit  15     = "done" flag
# The Nexys A7 top-level shows the GPIO register on the LEDs (switches select other views).
.equ MMIO,        0x80000000
.equ CNT_COND,    0x20
.equ CNT_MISP,    0x28
    li   sp, 0x3f00
    li   s0, MMIO
    li   t0, 0x01
    sd   t0, 0(s0)                 # LED0 on: running
    li   s1, 20000                 # iterations
    li   s2, 0x1234567812345678    # xorshift state
    li   s3, 0
    li   s4, 0                     # checksum
loop:
    andi t0, s3, 3
    bnez t0, pat_skip              # period-4 pattern  (history friendly)
    addi s4, s4, 1
pat_skip:
    slli t1, s2, 13
    xor  s2, s2, t1
    srli t1, s2, 7
    xor  s2, s2, t1
    slli t1, s2, 17
    xor  s2, s2, t1
    srli t1, s2, 40
    andi t1, t1, 7
    bnez t1, noisy_skip            # noisy, biased 7/8
    call leaf
noisy_skip:
    andi t1, s3, 15
    li   t2, 9
    blt  t1, t2, lo_skip           # longer pattern: taken for 9 of 16 iterations
    addi s4, s4, 3
lo_skip:
    addi s3, s3, 1
    blt  s3, s1, loop

    # ---- accuracy = (cond - mispredicted) * 100 / cond --------------------------------
    ld   t0, CNT_COND(s0)
    ld   t1, CNT_MISP(s0)
    sub  t2, t0, t1
    slli t3, t2, 6                 # *64
    slli t4, t2, 5                 # *32
    add  t3, t3, t4
    slli t4, t2, 2                 # *4
    add  t3, t3, t4                # t3 = correct * 100
    li   a0, 0
div:
    blt  t3, t0, div_done          # repeated subtraction (at most 100 iterations)
    sub  t3, t3, t0
    addi a0, a0, 1
    j    div
div_done:
    li   t5, 0x8000
    or   t5, t5, a0
    sd   t5, 0(s0)                 # publish: done flag + accuracy
    ecall
leaf:
    addi s4, s4, 7
    ret
