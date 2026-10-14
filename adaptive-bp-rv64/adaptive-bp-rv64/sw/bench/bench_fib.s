# Recursive Fibonacci: thousands of call/return pairs, exercises BTB (calls) and RAS (returns).
    li   sp, 0x3f00
    li   a0, 17
    call fib                      # fib(17) = 1597
    ecall
fib:
    li   t0, 2
    blt  a0, t0, fib_ret
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
fib_ret:
    ret
