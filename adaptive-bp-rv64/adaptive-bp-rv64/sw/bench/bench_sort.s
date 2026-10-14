# Bubble sort of 40 pseudo-random 64-bit values: data-dependent compare/swap branches
# whose bias drifts as the array becomes sorted.  a0 = checksum of the sorted array.
.equ N, 40
.data
arr:    .zero 320
.text
    li   sp, 0x3f00
    la   s0, arr
    li   s2, 0x9E3779B97F4A7C15
    li   t0, 0                   # fill
fill:
    slli t1, s2, 13
    xor  s2, s2, t1
    srli t1, s2, 7
    xor  s2, s2, t1
    slli t1, s2, 17
    xor  s2, s2, t1
    slli t2, t0, 3
    add  t2, t2, s0
    srli t3, s2, 16             # keep values positive & small enough to compare signed
    sd   t3, 0(t2)
    addi t0, t0, 1
    li   t4, N
    blt  t0, t4, fill

    li   s1, N
outer:                           # for (i = N; i > 1; i--)
    li   t0, 0
    addi s3, s1, -1
inner:                           # for (j = 0; j < i-1; j++)
    slli t1, t0, 3
    add  t1, t1, s0
    ld   t2, 0(t1)
    ld   t3, 8(t1)
    ble  t2, t3, noswap
    sd   t3, 0(t1)
    sd   t2, 8(t1)
noswap:
    addi t0, t0, 1
    blt  t0, s3, inner
    addi s1, s1, -1
    li   t4, 1
    bgt  s1, t4, outer

    li   a0, 0                   # checksum: sum(arr[i] * (i+1))  via shifts/adds
    li   t0, 0
chk:
    slli t1, t0, 3
    add  t1, t1, s0
    ld   t2, 0(t1)
    addi t3, t0, 1
cm: add  a0, a0, t2
    addi t3, t3, -1
    bnez t3, cm
    addi t0, t0, 1
    li   t4, N
    blt  t0, t4, chk
    ecall
