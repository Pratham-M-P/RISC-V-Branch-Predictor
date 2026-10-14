"""
Constrained-random RV64I program generator.

Every generated program is guaranteed to terminate and to stay inside the data
memory: loops use dedicated counters (s1..s3) that are never written by the loop
body, forward branches only skip a few instructions, calls target leaf functions,
loads/stores are naturally aligned and confined to a 256-byte window addressed
through s0.

The *constraints* (instruction mix, loop depth/trip counts, branch bias styles,
call density ...) are the knobs of `GenConfig`; the seed makes it reproducible.
"""
from __future__ import annotations

import random
from dataclasses import dataclass, field

DATA_REGS = ["a1", "a2", "a3", "a4", "a5", "a6", "a7", "t0", "t1", "t2", "t3", "t4"]
LOOP_REGS = ["s1", "s2", "s3"]
R_OPS = ["add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and",
         "addw", "subw", "sllw", "srlw", "sraw"]
I_OPS = ["addi", "slti", "sltiu", "xori", "ori", "andi", "addiw"]
SH_OPS = {"slli": 63, "srli": 63, "srai": 63, "slliw": 31, "srliw": 31, "sraiw": 31}
BR_OPS = ["beq", "bne", "blt", "bge", "bltu", "bgeu"]
LOADS = {"lb": 1, "lbu": 1, "lh": 2, "lhu": 2, "lw": 4, "lwu": 4, "ld": 8}
STORES = {"sb": 1, "sh": 2, "sw": 4, "sd": 8}


@dataclass
class GenConfig:
    n_items: int = 60                 # top-level items (blocks / loops / branches / calls)
    max_loop_depth: int = 3
    max_trip: int = 12
    w_alu: int = 10
    w_mem: int = 4
    w_branch: int = 5
    w_loop: int = 3
    w_call: int = 2
    w_indirect: int = 1
    n_funcs: int = 4
    patterned_branch_bias: float = 0.5   # probability a branch condition derives from a loop counter bit
    min_body: int = 2
    max_body: int = 6


class ProgGen:
    def __init__(self, seed: int, cfg: GenConfig | None = None):
        self.rng = random.Random(seed)
        self.cfg = cfg or GenConfig()
        self.lines: list[str] = []
        self.label_id = 0
        self.depth = 0
        self.active_counters: list[str] = []

    # ---- helpers --------------------------------------------------------- #
    def emit(self, s: str) -> None:
        self.lines.append("    " + s)

    def label(self, name: str) -> None:
        self.lines.append(f"{name}:")

    def new_label(self, prefix: str) -> str:
        self.label_id += 1
        return f"{prefix}{self.label_id}"

    def reg(self) -> str:
        return self.rng.choice(DATA_REGS)

    # ---- single instruction generators ------------------------------------- #
    def gen_alu(self) -> None:
        r = self.rng
        kind = r.random()
        rd = self.reg() if r.random() > 0.03 else "x0"
        if kind < 0.45:
            self.emit(f"{r.choice(R_OPS)} {rd}, {self.reg()}, {self.reg()}")
        elif kind < 0.70:
            self.emit(f"{r.choice(I_OPS)} {rd}, {self.reg()}, {r.randint(-2048, 2047)}")
        elif kind < 0.85:
            op = r.choice(list(SH_OPS))
            self.emit(f"{op} {rd}, {self.reg()}, {r.randint(0, SH_OPS[op])}")
        elif kind < 0.93:
            self.emit(f"li {rd}, {r.choice([r.randint(-2**63, 2**63 - 1), r.randint(-2**31, 2**31 - 1), r.randint(-9, 9)])}")
        elif kind < 0.97:
            self.emit(f"lui {rd}, {r.randint(0, 0xFFFFF)}")
        else:
            self.emit(f"auipc {rd}, {r.randint(0, 0xFFFFF)}")

    def gen_mem(self) -> None:
        r = self.rng
        if r.random() < 0.5:
            op = r.choice(list(LOADS))
            sz = LOADS[op]
            off = r.randrange(0, 256, sz)
            self.emit(f"{op} {self.reg()}, {off}(s0)")
        else:
            op = r.choice(list(STORES))
            sz = STORES[op]
            off = r.randrange(0, 256, sz)
            self.emit(f"{op} {self.reg()}, {off}(s0)")

    def gen_simple(self) -> None:
        if self.rng.random() < self.cfg.w_alu / (self.cfg.w_alu + self.cfg.w_mem):
            self.gen_alu()
        else:
            self.gen_mem()

    def gen_body(self, lo: int | None = None, hi: int | None = None) -> None:
        for _ in range(self.rng.randint(lo or self.cfg.min_body, hi or self.cfg.max_body)):
            self.gen_simple()

    # ---- control-flow constructs ------------------------------------------- #
    def gen_branch(self) -> None:
        r = self.rng
        skip = self.new_label("skip")
        if self.active_counters and r.random() < self.cfg.patterned_branch_bias:
            # periodic / biased pattern derived from a loop counter  -> history friendly
            cnt = r.choice(self.active_counters)
            mask = r.choice([1, 1, 3, 3, 7, 15])
            self.emit(f"andi t5, {cnt}, {mask}")
            self.emit(f"{r.choice(['beqz', 'bnez'])} t5, {skip}")
        else:
            self.emit(f"{r.choice(BR_OPS)} {self.reg()}, {self.reg()}, {skip}")
        self.gen_body(1, 4)
        self.label(skip)

    def gen_loop(self) -> None:
        r = self.rng
        cnt = LOOP_REGS[self.depth]
        top = self.new_label("loop")
        self.emit(f"li {cnt}, {r.randint(2, self.cfg.max_trip)}")
        self.label(top)
        self.depth += 1
        self.active_counters.append(cnt)
        for _ in range(r.randint(1, 4)):
            self.gen_item(allow_loop=self.depth < self.cfg.max_loop_depth)
        self.active_counters.pop()
        self.depth -= 1
        self.emit(f"addi {cnt}, {cnt}, -1")
        self.emit(f"bnez {cnt}, {top}")

    def gen_call(self) -> None:
        self.emit(f"call fn{self.rng.randrange(self.cfg.n_funcs)}")

    def gen_indirect(self) -> None:
        tgt = self.new_label("ind")
        self.emit(f"la t5, {tgt}")
        self.emit("jalr x0, 0(t5)")
        self.gen_body(1, 2)              # skipped by the jump
        self.label(tgt)

    def gen_item(self, allow_loop: bool = True) -> None:
        c = self.cfg
        choices = [("simple", c.w_alu + c.w_mem), ("branch", c.w_branch), ("call", c.w_call),
                   ("indirect", c.w_indirect)]
        if allow_loop and self.depth < c.max_loop_depth:
            choices.append(("loop", c.w_loop))
        kinds, weights = zip(*choices)
        k = self.rng.choices(kinds, weights)[0]
        if k == "simple":
            self.gen_body(1, self.cfg.max_body)
        elif k == "branch":
            self.gen_branch()
        elif k == "call":
            self.gen_call()
        elif k == "indirect":
            self.gen_indirect()
        else:
            self.gen_loop()

    # ---- whole program -------------------------------------------------------- #
    def generate(self) -> str:
        r = self.rng
        self.lines = ["# auto-generated random program", "    li   s0, 0x400            # scratch window base"]
        for reg in DATA_REGS:
            self.emit(f"li {reg}, {r.randint(-2**63, 2**63 - 1) if r.random() < 0.5 else r.randint(-100, 100)}")
        for _ in range(self.cfg.n_items):
            self.gen_item()
        # fold all data registers into a0 so that any corruption is visible
        self.emit("li a0, 0")
        for reg in DATA_REGS:
            self.emit(f"xor a0, a0, {reg}")
            self.emit("slli a0, a0, 1")
        self.emit("ecall")
        for i in range(self.cfg.n_funcs):
            self.label(f"fn{i}")
            for _ in range(r.randint(1, 5)):
                self.gen_alu()
            if r.random() < 0.5:                      # a small branchy leaf
                skip = self.new_label("fskip")
                self.emit(f"{r.choice(BR_OPS)} {self.reg()}, {self.reg()}, {skip}")
                self.gen_alu()
                self.label(skip)
            self.emit("ret")
        return "\n".join(self.lines) + "\n"


def generate(seed: int, cfg: GenConfig | None = None) -> str:
    return ProgGen(seed, cfg).generate()


if __name__ == "__main__":
    import sys
    print(generate(int(sys.argv[1]) if len(sys.argv) > 1 else 1))
