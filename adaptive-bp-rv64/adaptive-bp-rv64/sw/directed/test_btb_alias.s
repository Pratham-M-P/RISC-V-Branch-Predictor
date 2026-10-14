# Two taken branches whose PCs differ by 256 bytes map to the same BTB index with
# different tags -> they keep evicting each other.  Functional result must stay correct.
.include "../common.inc"
    TEST_INIT
    li   s1, 0
    li   s2, 40
    j    blockA
    .align 8                      # -> 0x100
blockA:
    addi s1, s1, 1                # 0x100
    beq  x0, x0, blockB           # 0x104  (always taken)
    .zero 0x1f8                   # pad to 0x300
blockB:
    addi s2, s2, -1               # 0x300
    bnez s2, blockA               # 0x304  same BTB index as 0x104
    CHECK s1, 40
    TEST_END
