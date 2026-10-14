# An illegal instruction must halt the machine (instructions after it never commit).
# Expected: halted with illegal=1.  (RTL-only convention; the ISS mirrors it.)
    li   a0, 5
    .word 0x02000033             # MUL (M extension): not implemented -> illegal
    li   a0, 99                  # must never execute
    ecall
