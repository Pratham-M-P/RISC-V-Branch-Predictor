#!/usr/bin/env python3
"""
Minimal two-pass RV64I assembler used by the project.

Supported
  * all RV64I base instructions that the core implements (no M/A/F/D/C, no CSRs)
  * the usual pseudo-instructions: nop mv not neg negw sext.w seqz snez sltz sgtz
    li la j jr ret call tail beqz bnez blez bgez bltz bgtz bgt ble bgtu bleu
  * directives: .text .data .word .dword .half .byte .zero .space .align .equ .set
    .globl/.global (ignored)
  * .include "file" and simple .macro/.endm macros (args referenced as \\name, \\@ = unique id)
  * labels, `#` and `//` comments, numeric expressions with + - * << >> & | ( )

Memory model (Harvard, matching the RTL):
  * the instruction image starts at address 0x0 and is emitted one 32-bit word per line
  * the data image starts at address DATA_BASE (default 0x0 in the *data* space)
    and is emitted one 64-bit little-endian word per line

Usage:  python -m rvtools.asm prog.s -o prog.hex [-d prog.dhex] [--listing prog.lst]
"""
from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

# --------------------------------------------------------------------------- #
# registers
# --------------------------------------------------------------------------- #
_ABI = ["zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2", "s0", "s1"] + \
       [f"a{i}" for i in range(8)] + [f"s{i}" for i in range(2, 12)] + \
       [f"t{i}" for i in range(3, 7)]
REGS: dict[str, int] = {name: i for i, name in enumerate(_ABI)}
REGS.update({f"x{i}": i for i in range(32)})
REGS["fp"] = 8


class AsmError(Exception):
    pass


def reg(tok: str) -> int:
    tok = tok.strip().lower()
    if tok not in REGS:
        raise AsmError(f"unknown register '{tok}'")
    return REGS[tok]


# --------------------------------------------------------------------------- #
# encoders
# --------------------------------------------------------------------------- #
def _sext(v: int, bits: int) -> int:
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


def _chk(v: int, bits: int, what: str, signed: bool = True) -> int:
    lo, hi = (-(1 << (bits - 1)), (1 << (bits - 1)) - 1) if signed else (0, (1 << bits) - 1)
    if not lo <= v <= hi:
        raise AsmError(f"{what} {v} out of range [{lo}, {hi}]")
    return v & ((1 << bits) - 1)


def enc_r(opc, f3, f7, rd, rs1, rs2):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | opc


def enc_i(opc, f3, rd, rs1, imm):
    return (_chk(imm, 12, "imm12") << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | opc


def enc_s(opc, f3, rs1, rs2, imm):
    i = _chk(imm, 12, "imm12")
    return ((i >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((i & 0x1F) << 7) | opc


def enc_b(opc, f3, rs1, rs2, off):
    if off % 2:
        raise AsmError("branch offset not even")
    i = _chk(off, 13, "branch offset")
    return (((i >> 12) & 1) << 31) | (((i >> 5) & 0x3F) << 25) | (rs2 << 20) | (rs1 << 15) | \
           (f3 << 12) | (((i >> 1) & 0xF) << 8) | (((i >> 11) & 1) << 7) | opc


def enc_u(opc, rd, imm20):
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | opc


def enc_j(opc, rd, off):
    if off % 2:
        raise AsmError("jump offset not even")
    i = _chk(off, 21, "jump offset")
    return (((i >> 20) & 1) << 31) | (((i >> 1) & 0x3FF) << 21) | (((i >> 11) & 1) << 20) | \
           (((i >> 12) & 0xFF) << 12) | (rd << 7) | opc


OPC_LOAD, OPC_OPIMM, OPC_AUIPC, OPC_OPIMM32 = 0x03, 0x13, 0x17, 0x1B
OPC_STORE, OPC_OP, OPC_LUI, OPC_OP32 = 0x23, 0x33, 0x37, 0x3B
OPC_BRANCH, OPC_JALR, OPC_JAL, OPC_SYSTEM = 0x63, 0x67, 0x6F, 0x73

R_OPS = {  # name: (opcode, funct3, funct7)
    "add": (OPC_OP, 0, 0), "sub": (OPC_OP, 0, 0x20), "sll": (OPC_OP, 1, 0), "slt": (OPC_OP, 2, 0),
    "sltu": (OPC_OP, 3, 0), "xor": (OPC_OP, 4, 0), "srl": (OPC_OP, 5, 0), "sra": (OPC_OP, 5, 0x20),
    "or": (OPC_OP, 6, 0), "and": (OPC_OP, 7, 0),
    "addw": (OPC_OP32, 0, 0), "subw": (OPC_OP32, 0, 0x20), "sllw": (OPC_OP32, 1, 0),
    "srlw": (OPC_OP32, 5, 0), "sraw": (OPC_OP32, 5, 0x20),
}
I_OPS = {"addi": 0, "slti": 2, "sltiu": 3, "xori": 4, "ori": 6, "andi": 7}
SH_OPS = {  # name: (opcode, funct3, upper-imm bits, shamt bits)
    "slli": (OPC_OPIMM, 1, 0x000, 6), "srli": (OPC_OPIMM, 5, 0x000, 6), "srai": (OPC_OPIMM, 5, 0x400, 6),
    "slliw": (OPC_OPIMM32, 1, 0x000, 5), "srliw": (OPC_OPIMM32, 5, 0x000, 5), "sraiw": (OPC_OPIMM32, 5, 0x400, 5),
}
LOADS = {"lb": 0, "lh": 1, "lw": 2, "ld": 3, "lbu": 4, "lhu": 5, "lwu": 6}
STORES = {"sb": 0, "sh": 1, "sw": 2, "sd": 3}
BRANCHES = {"beq": 0, "bne": 1, "blt": 4, "bge": 5, "bltu": 6, "bgeu": 7}

# --------------------------------------------------------------------------- #
# data structures
# --------------------------------------------------------------------------- #
_NUM_ONLY = re.compile(r"^[0-9a-fA-Fx+\-*()<>&|~ ]+$")


@dataclass
class Line:
    src: str
    lineno: int
    section: str
    addr: int
    mnemonic: str
    args: list[str]
    size: int


@dataclass
class Program:
    words: list[int] = field(default_factory=list)
    data: bytearray = field(default_factory=bytearray)
    symbols: dict[str, int] = field(default_factory=dict)
    listing: list[str] = field(default_factory=list)

    def imem_hex(self) -> str:
        return "".join(f"{w & 0xFFFFFFFF:08x}\n" for w in self.words)

    def dmem_hex(self) -> str:
        d = bytes(self.data) + b"\0" * (-len(self.data) % 8)
        return "".join(f"{int.from_bytes(d[i:i + 8], 'little'):016x}\n" for i in range(0, len(d), 8))


# --------------------------------------------------------------------------- #
# li expansion
# --------------------------------------------------------------------------- #
def li_sequence(rd: int, value: int) -> list[tuple[str, tuple]]:
    """Return a list of (mnemonic, operands) that loads a 64-bit constant."""
    value = _sext(value, 64)
    if -2048 <= value < 2048:
        return [("addi", (rd, 0, value))]
    if -(1 << 31) <= value < (1 << 31):
        hi = ((value + 0x800) >> 12) & 0xFFFFF
        lo = _sext(value, 12)
        seq = [("lui", (rd, hi))]
        if lo:
            seq.append(("addiw", (rd, rd, lo)))
        return seq
    lo = _sext(value, 12)
    hi = (value - lo) >> 12
    seq = li_sequence(rd, hi)
    seq.append(("slli", (rd, rd, 12)))
    if lo:
        seq.append(("addi", (rd, rd, lo)))
    return seq


# --------------------------------------------------------------------------- #
# assembler
# --------------------------------------------------------------------------- #
class Assembler:
    def __init__(self, data_base: int = 0):
        self.data_base = data_base
        self.symbols: dict[str, int] = {}
        self.equs: dict[str, int] = {}
        self.lines: list[Line] = []

    # ---- expression evaluation -------------------------------------------- #
    def eval(self, expr: str, allow_forward: bool = True) -> int:
        expr = expr.strip()
        if not expr:
            raise AsmError("empty expression")
        if len(expr) == 3 and expr[0] == "'" and expr[2] == "'":
            return ord(expr[1])

        def sub(m):
            name = m.group(0)
            if re.fullmatch(r"0[xX][0-9a-fA-F]+", name) or name.isdigit():
                return name
            if name in self.equs:
                return str(self.equs[name])
            if name in self.symbols:
                return str(self.symbols[name])
            if not allow_forward:
                raise AsmError(f"symbol '{name}' not defined yet")
            raise AsmError(f"undefined symbol '{name}'")

        s = re.sub(r"[A-Za-z_.$][\w.$]*|0[xX][0-9a-fA-F]+|\d+", sub, expr)
        if not _NUM_ONLY.match(s):
            raise AsmError(f"bad expression '{expr}'")
        try:
            return int(eval(s, {"__builtins__": {}}, {}))  # noqa: S307 (sanitised above)
        except Exception as exc:  # pragma: no cover
            raise AsmError(f"cannot evaluate '{expr}': {exc}") from exc

    # ---- pass 1 -------------------------------------------------------------- #
    @staticmethod
    def _split_args(s: str) -> list[str]:
        out, depth, cur = [], 0, ""
        for ch in s:
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
            if ch == "," and depth == 0:
                out.append(cur.strip())
                cur = ""
            else:
                cur += ch
        if cur.strip():
            out.append(cur.strip())
        return out

    def _size_of(self, mn: str, args: list[str], section: str, cur: int) -> int:
        if mn.startswith("."):
            if mn in (".word", ".long"):
                return 4 * len(args)
            if mn == ".dword" or mn == ".quad":
                return 8 * len(args)
            if mn in (".half", ".short"):
                return 2 * len(args)
            if mn == ".byte":
                return len(args)
            if mn in (".zero", ".space", ".skip"):
                return self.eval(args[0])
            if mn == ".align":
                a = 1 << self.eval(args[0])
                return (-cur) % a
            return 0
        if mn == "li":
            try:
                return 4 * len(li_sequence(0, self.eval(args[1])))
            except AsmError:
                raise AsmError("li needs a constant known in pass 1 (use .equ before use or 'la')")
        if mn in ("la", "call"):
            return 8 if mn == "la" else 4
        return 4

    def pass1(self, text: str) -> None:
        section = "text"
        loc = {"text": 0, "data": self.data_base}
        for lineno, raw in enumerate(text.splitlines(), 1):
            line = re.split(r"#|//", raw, maxsplit=1)[0].strip()
            while True:
                m = re.match(r"^([A-Za-z_.$][\w.$]*)\s*:\s*(.*)$", line)
                if not m:
                    break
                lbl, line = m.group(1), m.group(2).strip()
                if lbl in self.symbols:
                    raise AsmError(f"line {lineno}: duplicate label '{lbl}'")
                self.symbols[lbl] = loc[section]
            if not line:
                continue
            parts = line.split(None, 1)
            mn = parts[0].lower()
            args = self._split_args(parts[1]) if len(parts) > 1 else []
            try:
                if mn == ".text":
                    section = "text"
                    continue
                if mn == ".data":
                    section = "data"
                    continue
                if mn in (".globl", ".global", ".section", ".type", ".size", ".option", ".file"):
                    continue
                if mn in (".equ", ".set"):
                    self.equs[args[0]] = self.eval(args[1])
                    continue
                size = self._size_of(mn, args, section, loc[section])
            except AsmError as exc:
                raise AsmError(f"line {lineno}: {exc}") from exc
            self.lines.append(Line(raw.rstrip(), lineno, section, loc[section], mn, args, size))
            loc[section] += size

    # ---- pass 2 -------------------------------------------------------------- #
    def _mem_operand(self, s: str) -> tuple[int, int]:
        m = re.match(r"^(.*)\((\s*\w+\s*)\)$", s.strip())
        if not m:
            raise AsmError(f"bad memory operand '{s}'")
        off = self.eval(m.group(1)) if m.group(1).strip() else 0
        return off, reg(m.group(2))

    def _enc(self, ln: Line) -> list[int]:
        mn, a, pc = ln.mnemonic, ln.args, ln.addr
        E = self.eval

        def need(n):
            if len(a) != n:
                raise AsmError(f"'{mn}' expects {n} operands, got {len(a)}")

        # --- pseudo-instructions ---
        if mn == "nop":
            return [enc_i(OPC_OPIMM, 0, 0, 0, 0)]
        if mn == "mv":
            need(2); return [enc_i(OPC_OPIMM, 0, reg(a[0]), reg(a[1]), 0)]
        if mn == "not":
            need(2); return [enc_i(OPC_OPIMM, 4, reg(a[0]), reg(a[1]), -1)]
        if mn == "neg":
            need(2); return [enc_r(OPC_OP, 0, 0x20, reg(a[0]), 0, reg(a[1]))]
        if mn == "negw":
            need(2); return [enc_r(OPC_OP32, 0, 0x20, reg(a[0]), 0, reg(a[1]))]
        if mn == "sext.w":
            need(2); return [enc_i(OPC_OPIMM32, 0, reg(a[0]), reg(a[1]), 0)]
        if mn == "seqz":
            need(2); return [enc_i(OPC_OPIMM, 3, reg(a[0]), reg(a[1]), 1)]
        if mn == "snez":
            need(2); return [enc_r(OPC_OP, 3, 0, reg(a[0]), 0, reg(a[1]))]
        if mn == "sltz":
            need(2); return [enc_r(OPC_OP, 2, 0, reg(a[0]), reg(a[1]), 0)]
        if mn == "sgtz":
            need(2); return [enc_r(OPC_OP, 2, 0, reg(a[0]), 0, reg(a[1]))]
        if mn == "li":
            need(2)
            return [self._enc_one(m2, ops, pc + 4 * i) for i, (m2, ops) in
                    enumerate(li_sequence(reg(a[0]), E(a[1])))]
        if mn == "la":
            need(2)
            v = E(a[1]); rd = reg(a[0])
            if not 0 <= v < (1 << 31) - 0x800:
                raise AsmError("la target out of 31-bit range")
            hi = ((v + 0x800) >> 12) & 0xFFFFF
            return [enc_u(OPC_LUI, rd, hi), enc_i(OPC_OPIMM32, 0, rd, rd, _sext(v, 12))]
        if mn == "j":
            need(1); return [enc_j(OPC_JAL, 0, E(a[0]) - pc)]
        if mn == "jal" and len(a) == 1:
            return [enc_j(OPC_JAL, 1, E(a[0]) - pc)]
        if mn == "call":
            need(1); return [enc_j(OPC_JAL, 1, E(a[0]) - pc)]
        if mn == "tail":
            need(1); return [enc_j(OPC_JAL, 0, E(a[0]) - pc)]
        if mn == "jr":
            need(1); return [enc_i(OPC_JALR, 0, 0, reg(a[0]), 0)]
        if mn == "ret":
            return [enc_i(OPC_JALR, 0, 0, 1, 0)]
        if mn == "jalr" and len(a) == 1:
            return [enc_i(OPC_JALR, 0, 1, reg(a[0]), 0)]
        for pname, (base, swap) in {"beqz": ("beq", False), "bnez": ("bne", False),
                                    "bltz": ("blt", False), "bgez": ("bge", False),
                                    "blez": ("bge", True), "bgtz": ("blt", True)}.items():
            if mn == pname:
                need(2)
                r = reg(a[0])
                rs1, rs2 = (0, r) if swap else (r, 0)
                return [enc_b(OPC_BRANCH, BRANCHES[base], rs1, rs2, E(a[1]) - pc)]
        for pname, base in {"bgt": "blt", "ble": "bge", "bgtu": "bltu", "bleu": "bgeu"}.items():
            if mn == pname:
                need(3)
                return [enc_b(OPC_BRANCH, BRANCHES[base], reg(a[1]), reg(a[0]), E(a[2]) - pc)]
        return [self._enc_native(mn, a, pc)]

    def _enc_one(self, mn: str, ops: tuple, pc: int) -> int:
        """Encode an already-resolved (mnemonic, numeric operands) tuple from li_sequence."""
        if mn == "lui":
            return enc_u(OPC_LUI, ops[0], ops[1])
        if mn == "addi":
            return enc_i(OPC_OPIMM, 0, ops[0], ops[1], ops[2])
        if mn == "addiw":
            return enc_i(OPC_OPIMM32, 0, ops[0], ops[1], ops[2])
        if mn == "slli":
            return enc_i(OPC_OPIMM, 1, ops[0], ops[1], ops[2])
        raise AsmError(f"internal: {mn}")

    def _enc_native(self, mn: str, a: list[str], pc: int) -> int:
        E = self.eval
        if mn in R_OPS:
            opc, f3, f7 = R_OPS[mn]
            return enc_r(opc, f3, f7, reg(a[0]), reg(a[1]), reg(a[2]))
        if mn in I_OPS:
            return enc_i(OPC_OPIMM, I_OPS[mn], reg(a[0]), reg(a[1]), E(a[2]))
        if mn == "addiw":
            return enc_i(OPC_OPIMM32, 0, reg(a[0]), reg(a[1]), E(a[2]))
        if mn in SH_OPS:
            opc, f3, up, bits = SH_OPS[mn]
            sh = _chk(E(a[2]), bits, "shamt", signed=False)
            return enc_i(opc, f3, reg(a[0]), reg(a[1]), _sext(up | sh, 12))
        if mn in LOADS:
            off, rs1 = self._mem_operand(a[1])
            return enc_i(OPC_LOAD, LOADS[mn], reg(a[0]), rs1, off)
        if mn in STORES:
            off, rs1 = self._mem_operand(a[1])
            return enc_s(OPC_STORE, STORES[mn], rs1, reg(a[0]), off)
        if mn in BRANCHES:
            return enc_b(OPC_BRANCH, BRANCHES[mn], reg(a[0]), reg(a[1]), E(a[2]) - pc)
        if mn == "lui":
            return enc_u(OPC_LUI, reg(a[0]), E(a[1]))
        if mn == "auipc":
            return enc_u(OPC_AUIPC, reg(a[0]), E(a[1]))
        if mn == "jal":
            return enc_j(OPC_JAL, reg(a[0]), E(a[1]) - pc)
        if mn == "jalr":
            if len(a) == 3:
                return enc_i(OPC_JALR, 0, reg(a[0]), reg(a[1]), E(a[2]))
            if len(a) == 2:
                off, rs1 = self._mem_operand(a[1])
                return enc_i(OPC_JALR, 0, reg(a[0]), rs1, off)
        if mn == "ecall":
            return 0x00000073
        if mn == "ebreak":
            return 0x00100073
        if mn == "fence":
            return 0x0FF0000F
        raise AsmError(f"unknown instruction '{mn}'")

    def pass2(self) -> Program:
        prog = Program(symbols=dict(self.symbols))
        text_words: dict[int, int] = {}
        data = bytearray()
        for ln in self.lines:
            try:
                if ln.mnemonic.startswith("."):
                    blob = self._directive_bytes(ln)
                    if ln.section == "data":
                        off = ln.addr - self.data_base
                        data.extend(b"\0" * (off - len(data)))
                        data.extend(blob)
                    else:
                        for i in range(0, len(blob), 4):
                            text_words[ln.addr + i] = int.from_bytes(blob[i:i + 4].ljust(4, b"\0"), "little")
                    continue
                if ln.section != "text":
                    raise AsmError("instruction in .data section")
                words = self._enc(ln)
                if 4 * len(words) != ln.size:
                    raise AsmError(f"internal size mismatch ({4 * len(words)} vs {ln.size})")
                for i, w in enumerate(words):
                    text_words[ln.addr + 4 * i] = w
                    prog.listing.append(f"{ln.addr + 4 * i:08x}: {w:08x}  {ln.src.strip() if i == 0 else ''}")
            except AsmError as exc:
                raise AsmError(f"line {ln.lineno}: {exc}\n    {ln.src.strip()}") from exc
        end = max(text_words) + 4 if text_words else 0
        prog.words = [text_words.get(a, 0x00000013) for a in range(0, end, 4)]
        prog.data = data
        return prog

    def _directive_bytes(self, ln: Line) -> bytes:
        mn, a = ln.mnemonic, ln.args
        width = {".word": 4, ".long": 4, ".dword": 8, ".quad": 8, ".half": 2, ".short": 2, ".byte": 1}
        if mn in width:
            n = width[mn]
            return b"".join((self.eval(x) & ((1 << (8 * n)) - 1)).to_bytes(n, "little") for x in a)
        if mn in (".zero", ".space", ".skip"):
            return b"\0" * self.eval(a[0])
        if mn == ".align":
            pad = (-ln.addr) % (1 << self.eval(a[0]))
            return (b"\x13\x00\x00\x00" * (pad // 4)) if ln.section == "text" else b"\0" * pad
        raise AsmError(f"unknown directive {mn}")


def expand_macros(text: str) -> str:
    """Tiny .macro/.endm preprocessor (positional args referenced as \\name)."""
    macros: dict[str, tuple[list[str], list[str]]] = {}
    counter = [0]

    def expand(lines: list[str], depth: int = 0) -> list[str]:
        if depth > 16:
            raise AsmError("macro recursion too deep")
        out: list[str] = []
        i = 0
        while i < len(lines):
            raw = lines[i]
            code = re.split(r"#|//", raw, maxsplit=1)[0].strip()
            m = re.match(r"^\.macro\s+(\w+)\s*(.*)$", code)
            if m:
                params = [p.strip() for p in m.group(2).split(",") if p.strip()]
                body: list[str] = []
                i += 1
                while i < len(lines) and not lines[i].strip().startswith(".endm"):
                    body.append(lines[i])
                    i += 1
                macros[m.group(1)] = (params, body)
                i += 1
                continue
            tok = code.split(None, 1)
            if tok and tok[0] in macros:
                params, body = macros[tok[0]]
                args = Assembler._split_args(tok[1]) if len(tok) > 1 else []
                if len(args) != len(params):
                    raise AsmError(f"macro '{tok[0]}' expects {len(params)} args")
                sub = []
                counter[0] += 1
                for b in body:
                    for p, a in zip(params, args):
                        b = b.replace("\\" + p, a)
                    sub.append(b.replace("\\@", str(counter[0])))
                out.extend(expand(sub, depth + 1))
            else:
                out.append(raw)
            i += 1
        return out

    return "\n".join(expand(text.splitlines()))


def resolve_includes(text: str, base: Path | None, depth: int = 0) -> str:
    """Textually expand  .include "file"  (relative to the including file)."""
    if depth > 8:
        raise AsmError(".include nesting too deep")
    out = []
    for line in text.splitlines():
        m = re.match(r'^\s*\.include\s+"([^"]+)"', line)
        if m:
            if base is None:
                raise AsmError(".include used but no base directory known")
            inc = (base / m.group(1))
            out.append(resolve_includes(inc.read_text(), inc.parent, depth + 1))
        else:
            out.append(line)
    return "\n".join(out)


def assemble(text: str, data_base: int = 0, base_dir: Path | None = None) -> Program:
    text = expand_macros(resolve_includes(text, base_dir))
    asm = Assembler(data_base)
    asm.pass1(text)
    return asm.pass2()


def assemble_file(path: str | Path, data_base: int = 0) -> Program:
    path = Path(path)
    return assemble(path.read_text(), data_base, path.parent)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source")
    ap.add_argument("-o", "--output", required=True, help="instruction image (hex, 32-bit words)")
    ap.add_argument("-d", "--data", help="data image (hex, 64-bit words)")
    ap.add_argument("--listing", help="write an address/word/source listing")
    ap.add_argument("--data-base", type=lambda s: int(s, 0), default=0)
    args = ap.parse_args(argv)
    try:
        prog = assemble_file(args.source, args.data_base)
    except AsmError as exc:
        print(f"asm error: {args.source}: {exc}", file=sys.stderr)
        return 1
    Path(args.output).write_text(prog.imem_hex())
    if args.data:
        Path(args.data).write_text(prog.dmem_hex())
    if args.listing:
        Path(args.listing).write_text("\n".join(prog.listing) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
