#!/usr/bin/env python3
"""
run_flow.py -- simulation automation for the adaptive branch predictor project.

  test     directed self-checking programs (sw/directed) on every predictor type
  random   N constrained-random programs, RTL commit trace vs golden ISS
  bench    benchmark sweep over predictor types -> CSV / Markdown / PNG
  sweep    design-space sweep of table sizes on one benchmark
  regress  test + random + bench, non-zero exit status on any failure

Examples
  python python/run_flow.py test
  python python/run_flow.py random -n 100 --seed 7
  python python/run_flow.py bench --out results
  python python/run_flow.py regress --simulator xsim
"""
from __future__ import annotations

import argparse
import csv
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from rvtools.asm import assemble
from rvtools.progen import GenConfig, generate
from rvtools.sim import (BUILD, PREDICTORS, ROOT, FlowError, RtlParams, RunResult, assemble_to,
                         get_simulator, run_program)

DIRECTED = sorted((ROOT / "sw" / "directed").glob("*.s"))
BENCH = sorted((ROOT / "sw" / "bench").glob("*.s"))
EXPECT_ILLEGAL = {"test_illegal"}


def prebuild(sim, ptypes, base: RtlParams) -> None:
    """Build every predictor variant up front (in parallel) so runs don't race."""
    plist = [RtlParams(**{**base.__dict__, "PREDICTOR_TYPE": t}) for t in ptypes]
    with ThreadPoolExecutor(max_workers=min(4, len(plist))) as ex:
        list(ex.map(sim.build, plist))


def cmd_test(args, sim) -> int:
    ptypes = [0, 1, 2, 3] if args.all_predictors else [3]
    prebuild(sim, ptypes, RtlParams())
    fails = 0
    print(f"{'test':22s} {'pred':10s} {'cycles':>8s} {'IPC':>6s} {'result':s}")
    for src in DIRECTED:
        hexf, dhex = assemble_to(src, BUILD / "hex")
        for t in ptypes:
            r = run_program(sim, RtlParams(PREDICTOR_TYPE=t), hexf, dhex)
            if src.stem in EXPECT_ILLEGAL:
                ok = r.halted and r.illegal and r.a0 == 5 and r.trace_ok
            else:
                ok = r.halted and not r.illegal and r.a0 == 0 and r.trace_ok
            fails += not ok
            msg = "PASS" if ok else f"FAIL (a0={r.a0}, trace: {r.trace_msg})"
            print(f"{src.stem:22s} {PREDICTORS[t]:10s} {r.cycles:8d} {r.ipc:6.3f} {msg}")
    print(f"directed tests: {'ALL PASS' if not fails else f'{fails} FAILED'}")
    return fails


def cmd_random(args, sim) -> int:
    ptypes = [0, 1, 2, 3]
    prebuild(sim, ptypes, RtlParams())
    outdir = BUILD / "random"
    outdir.mkdir(parents=True, exist_ok=True)
    fails = 0
    cfgs = [GenConfig(), GenConfig(n_items=40, max_trip=30, w_loop=6, patterned_branch_bias=0.8),
            GenConfig(n_items=80, w_call=6, w_indirect=4, n_funcs=6)]
    for i in range(args.n):
        seed = args.seed + i
        cfg = cfgs[i % len(cfgs)]
        src = outdir / f"rand_{seed}.s"
        src.write_text(generate(seed, cfg))
        hexf, dhex = assemble_to(src, outdir)
        t = ptypes[i % len(ptypes)]
        r = run_program(sim, RtlParams(PREDICTOR_TYPE=t), hexf, dhex)
        ok = r.halted and not r.illegal and r.trace_ok
        fails += not ok
        if not ok or args.verbose:
            print(f"seed {seed:5d} {PREDICTORS[t]:10s} {'PASS' if ok else 'FAIL ' + r.trace_msg}")
    print(f"random programs: {args.n} run, {'ALL PASS' if not fails else f'{fails} FAILED'}")
    return fails


def bench_matrix(sim, base: RtlParams):
    prebuild(sim, [0, 1, 2, 3], base)
    rows = []
    for src in BENCH:
        hexf, dhex = assemble_to(src, BUILD / "hex")
        for t in (0, 1, 2, 3):
            p = RtlParams(**{**base.__dict__, "PREDICTOR_TYPE": t})
            r = run_program(sim, p, hexf, dhex)
            rows.append(r)
    return rows


def write_reports(rows: list[RunResult], out: Path) -> None:
    out.mkdir(parents=True, exist_ok=True)
    with open(out / "bench_results.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["benchmark", "predictor", "cycles", "instret", "ipc", "cond_branches",
                    "cond_mispredicts", "accuracy_pct", "ctrl_mispredicts", "mpki", "trace_ok"])
        for r in rows:
            w.writerow([r.program, PREDICTORS[r.params.PREDICTOR_TYPE], r.cycles, r.instret,
                        f"{r.ipc:.4f}", r.cond_br, r.cond_mp, f"{r.accuracy:.2f}", r.ctrl_mp,
                        f"{r.mpki:.2f}", r.trace_ok])
    progs = sorted({r.program for r in rows})
    md = ["| benchmark | " + " | ".join(f"{PREDICTORS[t]} acc% / IPC" for t in range(4)) + " |",
          "|---|" + "---|" * 4]
    for p in progs:
        cells = []
        for t in range(4):
            r = next(x for x in rows if x.program == p and x.params.PREDICTOR_TYPE == t)
            cells.append(f"{r.accuracy:.1f} / {r.ipc:.3f}")
        md.append(f"| {p} | " + " | ".join(cells) + " |")
    (out / "bench_results.md").write_text("\n".join(md) + "\n")
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        fig, axes = plt.subplots(1, 2, figsize=(12, 4))
        width = 0.2
        for k, (attr, title) in enumerate([("accuracy", "Conditional-branch accuracy [%]"), ("ipc", "IPC")]):
            for t in range(4):
                vals = [getattr(next(x for x in rows if x.program == p and x.params.PREDICTOR_TYPE == t), attr)
                        for p in progs]
                axes[k].bar([i + (t - 1.5) * width for i in range(len(progs))], vals, width, label=PREDICTORS[t])
            axes[k].set_xticks(range(len(progs)))
            axes[k].set_xticklabels([p.replace("bench_", "") for p in progs], rotation=30)
            axes[k].set_title(title)
        axes[0].set_ylim(40, 101)
        axes[0].legend()
        fig.tight_layout()
        fig.savefig(out / "bench_results.png", dpi=130)
    except ImportError:
        print("(matplotlib not installed: skipping PNG)")


def cmd_bench(args, sim) -> int:
    rows = bench_matrix(sim, RtlParams())
    bad = [r for r in rows if not r.trace_ok or not r.halted]
    write_reports(rows, Path(args.out))
    print((Path(args.out) / "bench_results.md").read_text())
    print(f"reports written to {args.out}/")
    return len(bad)


def cmd_sweep(args, sim) -> int:
    src = ROOT / "sw" / "bench" / f"{args.benchmark}.s"
    hexf, dhex = assemble_to(src, BUILD / "hex")
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    lines = ["idx_bits,predictor,accuracy_pct,ipc"]
    for bits in (4, 6, 8, 10, 12):
        for t in (1, 2, 3):
            p = RtlParams(PREDICTOR_TYPE=t, BIM_IDX_W=bits, GSH_IDX_W=bits, CHO_IDX_W=bits)
            r = run_program(sim, p, hexf, dhex, compare=False)
            lines.append(f"{bits},{PREDICTORS[t]},{r.accuracy:.2f},{r.ipc:.4f}")
            print(lines[-1])
    (out / f"sweep_{args.benchmark}.csv").write_text("\n".join(lines) + "\n")
    return 0


def cmd_regress(args, sim) -> int:
    args.all_predictors = True
    f = cmd_test(args, sim)
    f += cmd_random(args, sim)
    f += cmd_bench(args, sim)
    print("REGRESSION", "PASSED" if f == 0 else f"FAILED ({f})")
    return f


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--simulator", choices=["verilator", "xsim", "questa"])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("test"); p.add_argument("--all-predictors", action="store_true")
    p = sub.add_parser("random"); p.add_argument("-n", type=int, default=40); p.add_argument("--seed", type=int, default=1)
    p.add_argument("-v", "--verbose", action="store_true")
    p = sub.add_parser("bench"); p.add_argument("--out", default="results")
    p = sub.add_parser("sweep"); p.add_argument("--benchmark", default="bench_mix"); p.add_argument("--out", default="results")
    p = sub.add_parser("regress"); p.add_argument("-n", type=int, default=40); p.add_argument("--seed", type=int, default=1)
    p.add_argument("--out", default="results"); p.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()
    try:
        sim = get_simulator(args.simulator)
        print(f"[flow] simulator: {sim.name}")
        return 1 if globals()[f"cmd_{args.cmd}"](args, sim) else 0
    except FlowError as exc:
        print(f"[flow] ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
