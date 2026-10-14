"""Unit tests for the Python tool chain (no simulator needed):  pytest python/tests"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import pytest
from rvtools.asm import AsmError, assemble, li_sequence
from rvtools.bpmodel import accuracy
from rvtools.iss import ISS, s64
from rvtools.progen import generate

ROOT = Path(__file__).resolve().parents[2]


def run(src: str) -> ISS:
    iss = ISS()
    iss.load_program(assemble(src).words)
    iss.run(100000)
    return iss


@pytest.mark.parametrize("enc,word", [
    ("addi x1, x0, 1", 0x00100093), ("add x3, x1, x2", 0x002081B3), ("sub x3, x1, x2", 0x402081B3),
    ("ld x5, 8(x6)", 0x00833283), ("sd x5, 8(x6)", 0x00533423), ("lui x1, 0x12345", 0x123450B7),
    ("ecall", 0x73), ("slli x1, x2, 63", 0x03F11093), ("srai x1, x2, 3", 0x40315093),
    ("addw x1, x2, x3", 0x003100BB), ("jalr x1, 0(x2)", 0x000100E7),
])
def test_encodings(enc, word):
    assert assemble(enc).words == [word]


def test_branch_and_jal_offsets():
    assert assemble("beq x1, x2, t\nnop\nt: nop").words[0] == 0x00208463
    assert assemble("j t\nnop\nt: nop").words[0] == 0x0080006F


@pytest.mark.parametrize("v", [0, 1, -1, 2047, -2048, 2048, 0x7FFFFFFF, -2**31, 2**31, 0xDEADBEEF,
                               0x123456789ABCDEF0, -2**63, 2**63 - 1])
def test_li_roundtrip(v):
    iss = run(f"li a0, {v}\necall")
    assert iss.regs[10] == v & (2**64 - 1)
    assert len(li_sequence(10, v)) <= 8


def test_errors():
    with pytest.raises(AsmError):
        assemble("addi x1, x0, 5000")
    with pytest.raises(AsmError):
        assemble("foo x1")
    with pytest.raises(AsmError):
        assemble("j nowhere")


def test_macro_unique_labels():
    src = ".macro M r\n bnez \\r, l_\\@\n nop\nl_\\@:\n.endm\n li a0,1\n M a0\n M a0\n ecall"
    p = assemble(src)
    assert len(p.words) == 6 and len({k for k in p.symbols if k.startswith("l_")}) == 2


def test_iss_semantics():
    iss = run("li a0, -1\nsrliw a1, a0, 1\nsraiw a2, a0, 1\nli a3, 5\nli a4, 7\nslt a5, a3, a4\necall")
    assert iss.regs[11] == 0x7FFFFFFF and s64(iss.regs[12]) == -1 and iss.regs[15] == 1


def test_iss_illegal_halts():
    assert run(".word 0x02000033\necall").illegal


def test_progen_terminates_and_is_deterministic():
    assert generate(5) == generate(5) and generate(5) != generate(6)
    for seed in range(30):
        iss = ISS()
        iss.load_program(assemble(generate(seed)).words)
        iss.run(2_000_000)
        assert iss.halted and not iss.illegal


def test_model_prefers_history_on_pattern():
    prog = assemble((ROOT / "sw/bench/bench_pattern.s").read_text())
    iss = ISS()
    iss.load_program(prog.words)
    iss.run()
    assert accuracy(iss, "gshare") > accuracy(iss, "bimodal") + 20
    assert accuracy(iss, "tournament") >= accuracy(iss, "bimodal")
