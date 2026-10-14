"""
Trace-driven software model of the predictors (bimodal / gshare / tournament).

Branch outcomes come from the golden ISS, predictors are updated *immediately* after each
branch (no pipeline delay, no BTB). The result is the accuracy an ideal-update predictor
would reach, a reference/upper bound for the RTL numbers in results/bench_results.md
(the RTL additionally suffers from BTB cold misses and delayed, speculative updates).

    python python/rvtools/bpmodel.py build/hex/bench_mix.hex
"""
from __future__ import annotations

import sys
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from rvtools.iss import ISS  # noqa: E402


def sat(c: int, taken: bool) -> int:
    return min(3, c + 1) if taken else max(0, c - 1)


@dataclass
class Tournament:
    kind: str = "tournament"          # bimodal | gshare | tournament
    bim_bits: int = 10
    gsh_bits: int = 10
    cho_bits: int = 10
    bim: list[int] = field(default_factory=list)
    gsh: list[int] = field(default_factory=list)
    cho: list[int] = field(default_factory=list)
    ghr: int = 0

    def __post_init__(self):
        self.bim = [1] * (1 << self.bim_bits)
        self.gsh = [1] * (1 << self.gsh_bits)
        self.cho = [1] * (1 << self.cho_bits)

    def predict_and_update(self, pc: int, taken: bool) -> bool:
        bi = (pc >> 2) & ((1 << self.bim_bits) - 1)
        gm = (1 << self.gsh_bits) - 1
        gi = ((pc >> 2) ^ self.ghr) & gm
        ci = (pc >> 2) & ((1 << self.cho_bits) - 1)
        bp, gp = self.bim[bi] >> 1, self.gsh[gi] >> 1
        pred = {"bimodal": bp, "gshare": gp, "tournament": gp if self.cho[ci] >> 1 else bp}[self.kind]
        if (bp == taken) != (gp == taken):
            self.cho[ci] = sat(self.cho[ci], gp == taken)
        self.bim[bi] = sat(self.bim[bi], taken)
        self.gsh[gi] = sat(self.gsh[gi], taken)
        self.ghr = ((self.ghr << 1) | int(taken)) & gm
        return bool(pred) == taken


def accuracy(iss: ISS, kind: str, bits: int = 10) -> float:
    m = Tournament(kind, bits, bits, bits)
    hit = tot = 0
    for ev in iss.branches:
        if ev.kind == "cond":
            tot += 1
            hit += m.predict_and_update(ev.pc, ev.taken)
    return 100.0 * hit / tot if tot else 100.0


if __name__ == "__main__":
    iss = ISS.from_files(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None)
    iss.run()
    for k in ("bimodal", "gshare", "tournament"):
        print(f"{k:11s} ideal-update accuracy: {accuracy(iss, k):6.2f}%")
