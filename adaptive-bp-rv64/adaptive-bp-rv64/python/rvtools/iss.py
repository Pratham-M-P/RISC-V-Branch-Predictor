#!/usr/bin/env python3
"""
Golden instruction-set simulator for the RV64I subset implemented by the core.

It mirrors the RTL's architectural behaviour (Harvard memories, wrap-around
addressing, ECALL/EBREAK/illegal -> halt, MMIO GPIO at 0x8000_0000) and writes the
same *commit trace* format as tb_core.sv:

    <pc:016x> <insn:08x> <rd:d> <wdata:016x>        (rd=0, wdata=0 when nothing is written)
"""
from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass, field
from pathlib import Path

M64 = (1 << 64) - 1
M32 = (1 << 32) - 1
MMIO_BASE = 0x8000_0000


def sx(v: int, bits: int) -> int:
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


def s64(v: int) -> int:
    return sx(v, 64)


def load_hex_words(path: str | Path, width_bits: int) -> list[int]:
    words = []
    for line in Path(path).read_text().splitlines():
        line = line.split("//")[0].strip()
        if line:
            words.append(int(line, 16))
    return words


@dataclass
class BranchEvent:
    pc: int
    kind: str          # 'cond' | 'jal' | 'jalr'
    taken: bool
    target: int
    is_call: bool = False
    is_ret: bool = False


@dataclass
class ISS:
    imem_words: int = 4096
    dmem_bytes: int = 16384
    imem: list[int] = field(default_factory=list)
    dmem: bytearray = field(default_factory=bytearray)
    regs: list[int] = field(default_factory=lambda: [0] * 32)
    pc: int = 0
    gpio: int = 0
    halted: bool = False
    illegal: bool = False
    instret: int = 0
    trace: list[tuple[int, int, int, int]] = field(default_factory=list)
    branches: list[BranchEvent] = field(default_factory=list)

    def __post_init__(self):
        if not self.imem:
            self.imem = [0x00000073] * self.imem_words
        if not self.dmem:
            self.dmem = bytearray(self.dmem_bytes)

    # ------------------------------------------------------------------ #
    def load_program(self, words: list[int], data: bytes = b"") -> None:
        for i, w in enumerate(words):
            self.imem[i] = w & M32
        self.dmem[:len(data)] = data

    @classmethod
    def from_files(cls, hex_path, dhex_path=None, **kw) -> "ISS":
        iss = cls(**kw)
        words = load_hex_words(hex_path, 32)
        data = b""
        if dhex_path and Path(dhex_path).exists():
            data = b"".join(w.to_bytes(8, "little") for w in load_hex_words(dhex_path, 64))
        iss.load_program(words, data)
        return iss

    # ---- memory ------------------------------------------------------ #
    def _ld(self, addr: int, n: int) -> int:
        addr &= M64
        if addr & 0x8000_0000:
            if (addr & 0x38) == 0:       # GPIO register; performance counters are not modelled
                return (self.gpio >> (8 * (addr & 7))) & ((1 << (8 * n)) - 1)
            return 0
        a = addr % self.dmem_bytes
        return int.from_bytes(self.dmem[a:a + n], "little")

    def _st(self, addr: int, n: int, val: int) -> None:
        addr &= M64
        val &= (1 << (8 * n)) - 1
        if addr & 0x8000_0000:
            if (addr & 0x38) == 0:
                sh = 8 * (addr & 7)
                mask = ((1 << (8 * n)) - 1) << sh
                self.gpio = (self.gpio & ~mask) | (val << sh)
            return
        a = addr % self.dmem_bytes
        self.dmem[a:a + n] = val.to_bytes(n, "little")

    # ---- execution --------------------------------------------------- #
    def step(self) -> None:
        pc = self.pc
        insn = self.imem[(pc >> 2) & (self.imem_words - 1)]
        op = insn & 0x7F
        rd = (insn >> 7) & 31
        f3 = (insn >> 12) & 7
        rs1 = (insn >> 15) & 31
        rs2 = (insn >> 20) & 31
        f7 = insn >> 25
        a, b = self.regs[rs1], self.regs[rs2]
        imm_i = sx(insn >> 20, 12)
        imm_s = sx(((insn >> 25) << 5) | ((insn >> 7) & 31), 12)
        imm_b = sx((((insn >> 31) & 1) << 12) | (((insn >> 7) & 1) << 11) |
                   (((insn >> 25) & 63) << 5) | (((insn >> 8) & 15) << 1), 13)
        imm_u = sx(insn & 0xFFFFF000, 32)
        imm_j = sx((((insn >> 31) & 1) << 20) | (((insn >> 12) & 255) << 12) |
                   (((insn >> 20) & 1) << 11) | (((insn >> 21) & 1023) << 1), 21)

        next_pc = (pc + 4) & M64
        wval: int | None = None
        halt = False
        sra_bit = (insn >> 30) & 1

        def alu(op3: int, x: int, y: int, sub: bool, w: bool) -> int:
            if w:
                xs, ys = x & M32, y & M32
                sh = y & 31
                if op3 == 0:
                    r = (xs - ys) if sub else (xs + ys)
                elif op3 == 1:
                    r = xs << sh
                elif op3 == 5:
                    r = (sx(xs, 32) >> sh) if sra_bit else (xs >> sh)
                else:
                    raise ValueError
                return sx(r & M32, 32) & M64
            sh = y & 63
            if op3 == 0:
                r = (x - y) if sub else (x + y)
            elif op3 == 1:
                r = x << sh
            elif op3 == 2:
                r = int(s64(x) < s64(y))
            elif op3 == 3:
                r = int(x < y)
            elif op3 == 4:
                r = x ^ y
            elif op3 == 5:
                r = (s64(x) >> sh) if sra_bit else (x >> sh)
            elif op3 == 6:
                r = x | y
            else:
                r = x & y
            return r & M64

        if op == 0x37:                       # LUI
            wval = imm_u & M64
        elif op == 0x17:                     # AUIPC
            wval = (pc + imm_u) & M64
        elif op == 0x6F:                     # JAL
            wval = (pc + 4) & M64
            next_pc = (pc + imm_j) & M64
            self.branches.append(BranchEvent(pc, "jal", True, next_pc, rd in (1, 5), False))
        elif op == 0x67 and f3 == 0:         # JALR
            wval = (pc + 4) & M64
            next_pc = ((a + imm_i) & ~1) & M64
            self.branches.append(BranchEvent(pc, "jalr", True, next_pc, rd in (1, 5),
                                             rd == 0 and rs1 in (1, 5)))
        elif op == 0x63 and f3 not in (2, 3):  # BRANCH
            sa, sb = s64(a), s64(b)
            taken = {0: a == b, 1: a != b, 4: sa < sb, 5: sa >= sb, 6: a < b, 7: a >= b}[f3]
            tgt = (pc + imm_b) & M64
            if taken:
                next_pc = tgt
            self.branches.append(BranchEvent(pc, "cond", taken, tgt))
        elif op == 0x03 and f3 != 7:         # LOAD
            addr = (a + imm_i) & M64
            n = 1 << (f3 & 3)
            v = self._ld(addr, n)
            wval = (sx(v, 8 * n) & M64) if f3 < 4 else v
        elif op == 0x23 and f3 < 4:          # STORE
            self._st((a + imm_s) & M64, 1 << f3, b)
        elif op == 0x13:                     # OP-IMM
            y = imm_i & M64
            if f3 == 5 or f3 == 1:
                y = (insn >> 20) & 63        # RTL uses imm[5:0] as shamt, imm[10] picks SRA
            wval = alu(f3, a, y, False, False)
        elif op == 0x1B and f3 in (0, 1, 5):  # OP-IMM-32
            y = imm_i & M64
            wval = alu(f3, a, y, False, True)
        elif op == 0x33 and f7 in (0, 0x20):  # OP
            wval = alu(f3, a, b, f3 == 0 and sra_bit == 1, False)
        elif op == 0x3B and f7 in (0, 0x20) and f3 in (0, 1, 5):  # OP-32
            wval = alu(f3, a, b, f3 == 0 and sra_bit == 1, True)
        elif op == 0x0F:                     # FENCE
            pass
        elif op == 0x73:                     # ECALL / EBREAK / (CSR treated as halt)
            halt = True
        else:                                # illegal -> halt
            halt = True
            self.illegal = True

        if wval is not None and rd != 0:
            self.regs[rd] = wval & M64
            self.trace.append((pc, insn, rd, wval & M64))
        else:
            self.trace.append((pc, insn, 0, 0))
        self.instret += 1
        self.pc = next_pc
        if halt:
            self.halted = True

    def run(self, max_steps: int = 5_000_000) -> int:
        n = 0
        while not self.halted and n < max_steps:
            self.step()
            n += 1
        return n

    # ------------------------------------------------------------------ #
    def trace_lines(self) -> list[str]:
        return [f"{pc:016x} {insn:08x} {rd} {d:016x}" for pc, insn, rd, d in self.trace]


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="RV64I golden ISS")
    ap.add_argument("hex")
    ap.add_argument("--dhex")
    ap.add_argument("--trace", help="write the commit trace to this file")
    ap.add_argument("--max-steps", type=int, default=5_000_000)
    args = ap.parse_args(argv)
    iss = ISS.from_files(args.hex, args.dhex)
    iss.run(args.max_steps)
    if args.trace:
        Path(args.trace).write_text("\n".join(iss.trace_lines()) + "\n")
    print(f"ISS instret={iss.instret} halted={int(iss.halted)} illegal={int(iss.illegal)} a0={s64(iss.regs[10])}")
    return 0 if iss.halted else 2


if __name__ == "__main__":
    sys.exit(main())
