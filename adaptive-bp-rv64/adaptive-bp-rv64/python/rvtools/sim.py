"""
Simulation flow helpers: build the plain testbench (tb/tb_core.sv) with
Verilator (default), Vivado xsim or Questa, run programs, parse results and
compare the RTL commit trace with the golden ISS.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

from .asm import AsmError, assemble_file
from .iss import ISS

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / "build"

PREDICTORS = {0: "none", 1: "bimodal", 2: "gshare", 3: "tournament"}

RESULT_RE = re.compile(
    r"RESULT cycles=(\d+) instret=(\d+) cond_br=(\d+) cond_mp=(\d+) ctrl=(\d+) ctrl_mp=(\d+) "
    r"a0=(-?\d+) halted=(\d) illegal=(\d)")


class FlowError(RuntimeError):
    pass


@dataclass
class RtlParams:
    PREDICTOR_TYPE: int = 3
    BIM_IDX_W: int = 10
    GSH_IDX_W: int = 10
    CHO_IDX_W: int = 10
    BTB_IDX_W: int = 6
    RAS_DEPTH: int = 8

    def tag(self) -> str:
        blob = json.dumps(self.__dict__, sort_keys=True)
        return f"p{self.PREDICTOR_TYPE}_" + hashlib.sha1(blob.encode()).hexdigest()[:8]


@dataclass
class RunResult:
    program: str
    params: RtlParams
    cycles: int = 0
    instret: int = 0
    cond_br: int = 0
    cond_mp: int = 0
    ctrl: int = 0
    ctrl_mp: int = 0
    a0: int = 0
    halted: bool = False
    illegal: bool = False
    trace_ok: bool | None = None
    trace_msg: str = ""
    log: str = ""

    @property
    def ipc(self) -> float:
        return self.instret / self.cycles if self.cycles else 0.0

    @property
    def accuracy(self) -> float:
        return 100.0 * (1 - self.cond_mp / self.cond_br) if self.cond_br else 100.0

    @property
    def mpki(self) -> float:
        return 1000.0 * self.ctrl_mp / self.instret if self.instret else 0.0


def _run(cmd: list[str], cwd: Path | None = None, check: bool = True, timeout: int | None = None) -> str:
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    out = proc.stdout + proc.stderr
    if check and proc.returncode != 0:
        raise FlowError(f"command failed ({proc.returncode}): {' '.join(cmd)}\n{out[-4000:]}")
    return out


def rtl_files() -> list[str]:
    files = []
    for line in (ROOT / "rtl" / "filelist.f").read_text().splitlines():
        line = line.split("//")[0].strip()
        if line:
            files.append(str(ROOT / line))
    return files


# --------------------------------------------------------------------------- #
class Simulator:
    """Base class: build(params) -> exe handle, run(handle, plusargs) -> stdout."""
    name = "?"

    def available(self) -> bool:
        raise NotImplementedError

    def build(self, params: RtlParams, force: bool = False) -> Path:
        raise NotImplementedError

    def run(self, handle: Path, plusargs: list[str], params: RtlParams, timeout: int = 600) -> str:
        raise NotImplementedError


class Verilator(Simulator):
    name = "verilator"

    def available(self) -> bool:
        return shutil.which("verilator") is not None

    def build(self, params: RtlParams, force: bool = False) -> Path:
        mdir = BUILD / "verilator" / params.tag()
        exe = mdir / "Vtb"
        if exe.exists() and not force:
            return exe
        mdir.mkdir(parents=True, exist_ok=True)
        cmd = ["verilator", "--binary", "--timing", "-Wno-fatal", "-Wno-lint", "-Wno-style",
               "--top-module", "tb_core", "-Mdir", str(mdir), "-o", "Vtb", "-O2"]
        for k, v in params.__dict__.items():
            cmd.append(f"-G{k}={v}")
        cmd += rtl_files() + [str(ROOT / "tb" / "tb_core.sv")]
        _run(cmd, cwd=ROOT)
        return exe

    def run(self, handle: Path, plusargs: list[str], params: RtlParams, timeout: int = 600) -> str:
        return _run([str(handle)] + plusargs, check=False, timeout=timeout)


class Xsim(Simulator):
    """Vivado xsim. Not exercised in CI (needs a Vivado install) but kept in sync."""
    name = "xsim"

    def available(self) -> bool:
        return shutil.which("xvlog") is not None

    def build(self, params: RtlParams, force: bool = False) -> Path:
        d = BUILD / "xsim" / params.tag()
        d.mkdir(parents=True, exist_ok=True)
        snap = d / "xsim.dir"
        if snap.exists() and not force:
            return d
        _run(["xvlog", "-sv"] + rtl_files() + [str(ROOT / "tb" / "tb_core.sv")], cwd=d)
        gen = []
        for k, v in params.__dict__.items():
            gen += ["-generic_top", f"{k}={v}"]
        _run(["xelab", "tb_core", "-s", "sim", "-debug", "off"] + gen, cwd=d)
        return d

    def run(self, handle: Path, plusargs: list[str], params: RtlParams, timeout: int = 600) -> str:
        cmd = ["xsim", "sim", "-R"]
        for pa in plusargs:
            cmd += ["-testplusarg", pa.lstrip("+")]
        return _run(cmd, cwd=handle, check=False, timeout=timeout)


class Questa(Simulator):
    name = "questa"

    def available(self) -> bool:
        return shutil.which("vsim") is not None

    def build(self, params: RtlParams, force: bool = False) -> Path:
        d = BUILD / "questa" / params.tag()
        d.mkdir(parents=True, exist_ok=True)
        if (d / "work").exists() and not force:
            return d
        _run(["vlog", "-sv"] + rtl_files() + [str(ROOT / "tb" / "tb_core.sv")], cwd=d)
        return d

    def run(self, handle: Path, plusargs: list[str], params: RtlParams, timeout: int = 600) -> str:
        gen = [f"-g{k}={v}" for k, v in params.__dict__.items()]
        return _run(["vsim", "-c", "tb_core"] + gen + ["-do", "run -all; quit"] + plusargs,
                    cwd=handle, check=False, timeout=timeout)


SIMULATORS = {"verilator": Verilator, "xsim": Xsim, "questa": Questa}


def get_simulator(name: str | None = None) -> Simulator:
    if name:
        sim = SIMULATORS[name]()
        if not sim.available():
            raise FlowError(f"simulator '{name}' not found in PATH")
        return sim
    for cls in (Verilator, Xsim, Questa):
        sim = cls()
        if sim.available():
            return sim
    raise FlowError("no simulator found (install verilator, or source the Vivado/Questa environment)")


# --------------------------------------------------------------------------- #
def assemble_to(src: Path, outdir: Path) -> tuple[Path, Path | None]:
    outdir.mkdir(parents=True, exist_ok=True)
    try:
        prog = assemble_file(src)
    except AsmError as exc:
        raise FlowError(f"{src}: {exc}") from exc
    hexf = outdir / (src.stem + ".hex")
    hexf.write_text(prog.imem_hex())
    dhex = None
    if prog.data:
        dhex = outdir / (src.stem + ".dhex")
        dhex.write_text(prog.dmem_hex())
    return hexf, dhex


def run_program(sim: Simulator, params: RtlParams, hexf: Path, dhex: Path | None = None,
                compare: bool = True, max_cycles: int = 3_000_000, trace_dir: Path | None = None,
                force_build: bool = False) -> RunResult:
    handle = sim.build(params, force=force_build)
    trace_dir = trace_dir or (BUILD / "traces")
    trace_dir.mkdir(parents=True, exist_ok=True)
    trace = trace_dir / f"{hexf.stem}.{params.tag()}.rtl.trace"
    if trace.exists():
        trace.unlink()
    plus = [f"+HEX={hexf}", f"+TRACE={trace}", f"+MAXCYCLES={max_cycles}", "+QUIET"]
    if dhex:
        plus.append(f"+DHEX={dhex}")
    out = sim.run(handle, plus, params)
    m = RESULT_RE.search(out)
    res = RunResult(program=hexf.stem, params=params, log=out)
    if not m:
        raise FlowError(f"no RESULT line from simulation of {hexf}:\n{out[-2000:]}")
    (res.cycles, res.instret, res.cond_br, res.cond_mp, res.ctrl, res.ctrl_mp,
     res.a0) = (int(m.group(i)) for i in range(1, 8))
    res.halted, res.illegal = bool(int(m.group(8))), bool(int(m.group(9)))
    if compare:
        res.trace_ok, res.trace_msg = compare_trace(trace, hexf, dhex)
    return res


def compare_trace(rtl_trace: Path, hexf: Path, dhex: Path | None) -> tuple[bool, str]:
    iss = ISS.from_files(hexf, dhex)
    iss.run()
    gold = iss.trace_lines()
    got = [ln.strip() for ln in rtl_trace.read_text().splitlines() if ln.strip()] if rtl_trace.exists() else []
    if got == gold:
        return True, f"{len(gold)} commits match"
    for i, (g, r) in enumerate(zip(gold, got)):
        if g != r:
            return False, f"first mismatch at commit #{i}: ISS[{g}] RTL[{r}]"
    return False, f"length mismatch: ISS={len(gold)} RTL={len(got)}"
