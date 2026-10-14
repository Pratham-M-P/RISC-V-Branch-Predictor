# calls / returns: recursion (fib), deeper-than-RAS nesting, indirect calls.
.include "../common.inc"
.text
    TEST_INIT
    li   a0, 12
    call fib
    CHECK a0, 144

    li   a0, 20
    call depth                  # 20 nested calls: overflows the 8-entry RAS
    CHECK a0, 20

    la   t0, func_a
    jalr ra, 0(t0)
    CHECK a0, 7
    la   t0, func_b
    jalr t0                     # jalr ra, 0(t0)
    CHECK a0, 9

    li   a0, 3
    call chain1
    CHECK a0, 33
    TEST_END

fib:
    li   t0, 2
    blt  a0, t0, fib_base
    addi sp, sp, -24
    sd   ra, 0(sp)
    sd   a0, 8(sp)
    addi a0, a0, -1
    call fib
    sd   a0, 16(sp)
    ld   a0, 8(sp)
    addi a0, a0, -2
    call fib
    ld   t0, 16(sp)
    add  a0, a0, t0
    ld   ra, 0(sp)
    addi sp, sp, 24
fib_base:
    ret

depth:
    beqz a0, depth_base
    addi sp, sp, -16
    sd   ra, 0(sp)
    addi a0, a0, -1
    call depth
    addi a0, a0, 1
    ld   ra, 0(sp)
    addi sp, sp, 16
depth_base:
    ret

func_a:
    li   a0, 7
    ret
func_b:
    li   a0, 9
    ret

chain1:                          # a0 -> a0 * 10 + 3 via three nested calls
    addi sp, sp, -16
    sd   ra, 0(sp)
    call chain2
    addi a0, a0, 10
    ld   ra, 0(sp)
    addi sp, sp, 16
    ret
chain2:
    addi sp, sp, -16
    sd   ra, 0(sp)
    call chain3
    addi a0, a0, 10
    ld   ra, 0(sp)
    addi sp, sp, 16
    ret
chain3:
    addi a0, a0, 10
    ret
