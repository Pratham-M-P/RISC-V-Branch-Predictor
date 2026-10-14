#!/usr/bin/env python3
"""
Elaboration / syntax check of the UVM testbenches without a commercial simulator,
using the open-source slang front end (pip install pyslang) and Accellera's UVM source.

  python scripts/slang_check.py bp     --uvm /path/to/uvm-core/src
  python scripts/slang_check.py core   --uvm /path/to/uvm-core/src
"""
import argparse
import sys
from pathlib import Path

import pyslang

ROOT = Path(__file__).resolve().parents[1]
SUITES = {
    "bp":   ("tb_bp_uvm_top", ["tb/uvm/bp"], ["tb/uvm/bp/bp_if.sv", "tb/uvm/bp/bp_uvm_pkg.sv", "tb/uvm/bp/tb_bp_uvm_top.sv"]),
    "core": ("tb_core_uvm_top", ["tb/uvm/core"], ["tb/uvm/core/core_if.sv", "tb/uvm/core/core_uvm_pkg.sv", "tb/uvm/core/tb_core_uvm_top.sv"]),
}


def rtl_list():
    out = []
    for ln in (ROOT / "rtl/filelist.f").read_text().splitlines():
        ln = ln.split("//")[0].strip()
        if ln:
            out.append(str(ROOT / ln))
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("suite", choices=SUITES)
    ap.add_argument("--uvm", required=True, help="path to uvm-core/src")
    args = ap.parse_args()
    top, incs, files = SUITES[args.suite]
    uvm = Path(args.uvm)
    cmd = ["slang", "--top", top, "-DUVM_NO_DPI", "--error-limit", "50", "-Wno-unused", "-Wno-missing-top",
           "--timescale", "1ns/1ps", "-I", str(uvm)]
    for i in incs:
        cmd += ["-I", str(ROOT / i)]
    cmd += [str(uvm / "uvm_pkg.sv")] + rtl_list() + [str(ROOT / f) for f in files]
    drv = pyslang.driver.Driver()
    drv.addStandardArgs()
    if not drv.parseCommandLine(" ".join(f'"{c}"' if " " in c else c for c in cmd)):
        return 2
    if not drv.processOptions():
        return 2
    ok = drv.parseAllSources() and drv.reportParseDiags()
    comp = drv.createCompilation()
    drv.reportCompilation(comp, False)
    ok = drv.reportDiagnostics(False) and ok
    print("slang:", "OK" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
