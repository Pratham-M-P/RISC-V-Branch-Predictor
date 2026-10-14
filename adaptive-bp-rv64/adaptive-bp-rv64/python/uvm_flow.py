#!/usr/bin/env python3
"""
uvm_flow.py -- launch the UVM testbenches with Vivado xsim (default) or Questa.

  bp    predictor-level UVM  (directed + constrained-random, ref-model scoreboard, coverage)
  core  whole-core UVM       (assembled / random programs checked against the golden ISS trace)

Examples
  python python/uvm_flow.py bp   --test bp_directed_test
  python python/uvm_flow.py bp   --test bp_random_test --ptype 3 --seeds 5
  python python/uvm_flow.py core --programs directed bench --random 20
  python python/uvm_flow.py core --simulator questa

Requires a simulator with UVM 1.2 (xsim ships it: `-L uvm`). The scripts only build the command
lines; nothing here needs a licence beyond the simulator itself.
"""
from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from rvtools.iss import ISS
from rvtools.progen import GenConfig, generate
from rvtools.sim import BUILD, ROOT, assemble_to, rtl_files

UVM_BUILD = BUILD / "uvm"
RESULT = re.compile(r"UVM_TEST_RESULT:\s*(PASS|FAIL)")


def sh(cmd, cwd, log: Path | None = None) -> str:
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    out = p.stdout + p.stderr
    if log:
        log.write_text(out)
    return out if p.returncode == 0 else out + f"\n[exit {p.returncode}]"


class XsimUvm:
    name = "xsim"

    def available(self): return shutil.which("xvlog") is not None

    def build(self, suite: str, top: str, srcs: list[str], incdir: str, generics: dict, d: Path) -> Path:
        d.mkdir(parents=True, exist_ok=True)
        out = sh(["xvlog", "-sv", "-L", "uvm", "-i", str(ROOT / incdir)] + srcs, d, d / "xvlog.log")
        if "ERROR" in out:
            raise SystemExit(f"xvlog failed:\n{out[-3000:]}")
        gen = [x for k, v in generics.items() for x in ("-generic_top", f"{k}={v}")]
        out = sh(["xelab", "-L", "uvm", top, "-s", "sim", "-timescale", "1ns/1ps", "-debug", "typical"] + gen, d, d / "xelab.log")
        if "ERROR" in out:
            raise SystemExit(f"xelab failed:\n{out[-3000:]}")
        return d

    def run(self, d: Path, plus: list[str], log: Path) -> str:
        cmd = ["xsim", "sim", "-R"] + [x for p in plus for x in ("-testplusarg", p)]
        return sh(cmd, d, log)


class QuestaUvm:
    name = "questa"

    def available(self): return shutil.which("vsim") is not None

    def build(self, suite, top, srcs, incdir, generics, d: Path) -> Path:
        d.mkdir(parents=True, exist_ok=True)
        out = sh(["vlog", "-sv", "-timescale", "1ns/1ps", f"+incdir+{ROOT / incdir}"] + srcs, d, d / "vlog.log")
        if "Error" in out:
            raise SystemExit(f"vlog failed:\n{out[-3000:]}")
        d.joinpath("generics").write_text(" ".join(f"-G{k}={v}" for k, v in generics.items()))
        return d

    def run(self, d: Path, plus: list[str], log: Path) -> str:
        gen = (d / "generics").read_text().split()
        cmd = ["vsim", "-c", "-voptargs=+acc", "work.%s" % self._top] + gen + [f"+{p}" for p in plus] + ["-do", "run -all; quit -f"]
        return sh(cmd, d, log)

    _top = ""


SIMS = {"xsim": XsimUvm, "questa": QuestaUvm}


def pick(name):
    if name:
        s = SIMS[name]()
        if not s.available():
            raise SystemExit(f"{name} not found in PATH")
        return s
    for c in SIMS.values():
        s = c()
        if s.available():
            return s
    raise SystemExit("no UVM-capable simulator found (source Vivado settings64 for xsim, or Questa)")


def summarize(out: str) -> tuple[bool, str]:
    m = RESULT.search(out)
    errs = re.search(r"UVM_ERROR\s*:\s*(\d+)", out)
    fatals = re.search(r"UVM_FATAL\s*:\s*(\d+)", out)
    bad = int(errs.group(1)) if errs else 0
    bad += int(fatals.group(1)) if fatals else 0
    ok = bool(m and m.group(1) == "PASS" and bad == 0)
    cov = re.findall(r"\[COV\][^\n]*", out)
    return ok, (cov[-1] if cov else "")


def cmd_bp(a) -> int:
    sim = pick(a.simulator)
    gen = {"PREDICTOR_TYPE": a.ptype}
    srcs = rtl_files()[:5] + [str(ROOT / f) for f in ("tb/uvm/bp/bp_if.sv", "tb/uvm/bp/bp_uvm_pkg.sv", "tb/uvm/bp/tb_bp_uvm_top.sv")]
    if isinstance(sim, QuestaUvm):
        sim._top = "tb_bp_uvm_top"
    d = sim.build("bp", "tb_bp_uvm_top", srcs, "tb/uvm/bp", gen, UVM_BUILD / f"bp_p{a.ptype}")
    fails = 0
    for seed in range(1, a.seeds + 1):
        log = d / f"{a.test}_s{seed}.log"
        out = sim.run(d, [f"UVM_TESTNAME={a.test}", f"ntb_random_seed={seed}", "UVM_VERBOSITY=UVM_LOW"] + a.plus, log)
        ok, cov = summarize(out)
        fails += not ok
        print(f"[{a.test} ptype={a.ptype} seed={seed}] {'PASS' if ok else 'FAIL'}  {cov}  (log: {log})")
    return fails


def cmd_core(a) -> int:
    sim = pick(a.simulator)
    gen = {"PREDICTOR_TYPE": a.ptype}
    srcs = rtl_files() + [str(ROOT / f) for f in ("tb/uvm/core/core_if.sv", "tb/uvm/core/core_uvm_pkg.sv", "tb/uvm/core/tb_core_uvm_top.sv")]
    if isinstance(sim, QuestaUvm):
        sim._top = "tb_core_uvm_top"
    d = sim.build("core", "tb_core_uvm_top", srcs, "tb/uvm/core", gen, UVM_BUILD / f"core_p{a.ptype}")
    progs: list[Path] = []
    work = UVM_BUILD / "programs"
    work.mkdir(parents=True, exist_ok=True)
    if "directed" in a.programs:
        progs += sorted((ROOT / "sw/directed").glob("*.s"))
    if "bench" in a.programs:
        progs += sorted((ROOT / "sw/bench").glob("*.s"))
    cfgs = [GenConfig(), GenConfig(n_items=40, max_trip=30, w_loop=6, patterned_branch_bias=0.8),
            GenConfig(n_items=80, w_call=6, w_indirect=4, n_funcs=6)]
    for i in range(a.random):
        p = work / f"rand_{a.seed + i}.s"
        p.write_text(generate(a.seed + i, cfgs[i % 3]))
        progs.append(p)
    fails = 0
    for src in progs:
        hexf, dhex = assemble_to(src, work)
        iss = ISS.from_files(hexf, dhex)
        iss.run()
        gold = work / f"{src.stem}.gold"
        gold.write_text("\n".join(iss.trace_lines()) + "\n")
        plus = ["UVM_VERBOSITY=UVM_LOW", f"HEX={hexf}", f"GOLDEN={gold}"] + ([f"DHEX={dhex}"] if dhex else [])
        log = d / f"{src.stem}.log"
        out = sim.run(d, plus, log)
        ok, cov = summarize(out)
        fails += not ok
        print(f"[core {src.stem:18s}] {'PASS' if ok else 'FAIL'}  {cov}")
    print(f"core UVM: {len(progs) - fails}/{len(progs)} passed")
    return fails


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--simulator", choices=list(SIMS))
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("bp")
    b.add_argument("--test", default="bp_directed_test",
                   choices=["bp_directed_test", "bp_random_test", "bp_stress_test"])
    b.add_argument("--ptype", type=int, default=3)
    b.add_argument("--seeds", type=int, default=1)
    b.add_argument("--plus", nargs="*", default=[], help="extra plusargs, e.g. NITEMS=4000")
    c = sub.add_parser("core")
    c.add_argument("--ptype", type=int, default=3)
    c.add_argument("--programs", nargs="*", default=["directed", "bench"], choices=["directed", "bench"])
    c.add_argument("--random", type=int, default=10)
    c.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    return 1 if (cmd_bp if a.cmd == "bp" else cmd_core)(a) else 0


if __name__ == "__main__":
    sys.exit(main())
