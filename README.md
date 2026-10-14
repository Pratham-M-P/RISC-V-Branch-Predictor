# Adaptive Branch Prediction for a 64-bit RISC-V Processor

[![ci](https://github.com/<your-user>/adaptive-bp-rv64/actions/workflows/ci.yml/badge.svg)](https://github.com/<your-user>/adaptive-bp-rv64/actions)

A modular **adaptive (tournament) branch prediction unit** integrated into a 5-stage, in-order
**RV64I** pipeline, written in SystemVerilog, with a complete verification environment
(**UVM** + plain-SV + Python golden model) and an **AMD Vivado** flow for the Nexys A7 FPGA board.

| | |
|---|---|
| **RTL** | SystemVerilog: BTB, bimodal, gshare, choice (meta) predictor, return-address stack, speculative GHR with recovery |
| **Core** | 5-stage RV64I pipeline (forwarding, load-use stall, branch resolve in EX, 2-cycle mispredict penalty) |
| **Verification** | UVM predictor env (directed + constrained-random, ref-model scoreboard, SVA, functional coverage), UVM core env (golden-trace scoreboard), RTL-vs-ISS lock-step regression, SV model equivalence check |
| **Automation** | Python: assembler, golden ISS, random program generator, regression/benchmark runner, UVM launcher |
| **FPGA** | Vivado batch flow, Nexys A7-100T top-level (MMCM, LED/switch display), on-board accuracy demo |

## Results

Conditional-branch prediction accuracy / IPC, measured on the RTL (`make bench`, Verilator):

| benchmark | none (always NT) | bimodal | gshare | **tournament** |
|---|---|---|---|---|
| loops (3 nested) | 9.5 / 0.624 | 90.4 / 0.940 | 99.1 / 0.994 | **99.4 / 0.996** |
| pattern (periodic outcomes) | 35.4 / 0.795 | 56.2 / 0.852 | 93.6 / 0.975 | **93.6 / 0.975** |
| mix (pattern + noisy + calls) | 12.4 / 0.718 | 87.1 / 0.950 | 92.8 / 0.971 | **93.6 / 0.974** |
| sort (bubble, data dependent) | 18.4 / 0.666 | 87.2 / 0.872 | 85.7 / 0.866 | **89.3 / 0.880** |
| lfsr (random + biased) | 48.8 / 0.834 | 81.4 / 0.933 | 80.2 / 0.929 | **81.4 / 0.933** |
| fib (call/return heavy) | 50.0 / 0.613 | 50.0 / 0.824 | 91.7 / 0.889 | 90.1 / 0.886 |

![results](docs/bench_results.png)

The tournament predictor tracks the better component per branch: bimodal-friendly workloads
(lfsr) and history-friendly ones (pattern) both end up near the best single predictor, and on mixed
code (mix, sort) it beats both. Pure random branches (`lfsr`) are a hard floor for any predictor.
Table size sweeps: `make sweep` (`results/sweep_*.csv`).

## Repository layout

```
rtl/bp/        bp_pkg, bp_counter_table, bp_btb, bp_ras, branch_predictor (top)
rtl/core/      rv64_pkg, rv64_alu, rv64_regfile, rv64_decoder, rv64_core (pipeline)
rtl/soc/       rv64_imem, rv64_dmem, rv64_soc (memories + MMIO GPIO/perf counters)
rtl/filelist.f compile order
tb/tb_core.sv                plain testbench (Verilator / xsim / Questa), commit-trace dump
tb/tb_bp_model_check.sv      RTL predictor vs SV reference model, random, every cycle
tb/uvm/bp/                   predictor-level UVM environment
tb/uvm/core/                 whole-core UVM environment
sw/directed/ sw/bench/ sw/demo/   assembly tests, benchmarks, FPGA demo
python/rvtools/  asm.py iss.py progen.py bpmodel.py sim.py
python/run_flow.py  uvm_flow.py   regression / benchmark / UVM launchers
fpga/          top_nexys_a7.sv, nexys_a7.xdc, build.tcl, program.tcl
scripts/       slang_check.py (open-source UVM elaboration check)
docs/          architecture.md, verification.md, fpga.md
.github/workflows/ci.yml
```

## Quick start

```bash
sudo apt install verilator g++ make        # or any recent Verilator >= 5.0
pip install -r requirements.txt

make lint            # Verilator -Wall
make unit            # Python tool-chain tests
make model-check     # RTL predictor == SV reference model, 4 predictor types
make regress         # everything above + directed + random + benchmarks (about 1-2 minutes)
```

Individual runs:

```bash
python python/run_flow.py test --all-predictors     # directed self-checking programs
python python/run_flow.py random -n 200 --seed 42   # random programs, RTL vs ISS commit trace
python python/run_flow.py bench --out results       # CSV + Markdown + PNG
python python/run_flow.py --simulator xsim regress  # same flow on Vivado xsim
```

UVM (needs xsim or Questa; UVM 1.2):

```bash
make uvm-bp   SIM=xsim      # directed, random (5 seeds), stress
make uvm-core SIM=xsim N=20 # asm tests + benchmarks + 20 random programs, golden trace scoreboard
```

FPGA (Vivado on PATH, Nexys A7-100T):

```bash
make fpga-build PTYPE=3     # -> build/fpga/p3/top_nexys_a7_p3.bit + utilization/timing/power reports
make fpga-program PTYPE=3
```

## Design summary

* **Fetch-stage prediction.** A direct-mapped **BTB** (taken-only allocation) says whether a PC is a
  redirecting instruction and of which type (cond / jump / call / return). Conditional direction comes from
  the **tournament**: a *bimodal* table (PC-indexed) and a *gshare* table (PC xor global history), arbitrated
  per PC by a *choice* table of 2-bit counters that only trains when the two components disagree.
  Returns use a **RAS**. `PREDICTOR_TYPE` (0 none / 1 bimodal / 2 gshare / 3 tournament) selects the flavour.
* **Speculation and recovery.** GHR and RAS are updated speculatively at fetch. Each prediction returns a
  metadata word (GHR snapshot, component predictions, RAS pointer) that rides down the pipeline and is handed back
  at resolution for training and rollback. A mispredict is defined as *fetched next-PC != real next-PC*, which also
  catches BTB aliasing on non-branches.
* **Pipeline.** IF/ID/EX/MEM/WB, forwarding from EX/MEM and MEM/WB, load-use stall, branch resolution in EX
  (2-cycle penalty), ECALL/EBREAK/illegal halts. Not implemented: M/A/F/D/C, CSRs, interrupts, misaligned accesses.

Details: [docs/architecture.md](docs/architecture.md).

## Verification summary

| Level | What | Where |
|---|---|---|
| Unit (Python) | assembler encodings, `li` expansion, ISS semantics, random-program termination | `python/tests` |
| Predictor equivalence | 200k random cycles/type, RTL vs independent SV model (outputs + metadata) | `tb/tb_bp_model_check.sv` |
| Core lock-step | every committed instruction (pc, encoding, rd, data) vs golden ISS, for directed + benchmark + random programs, all predictor types | `run_flow.py` |
| UVM predictor | pipeline-like driver incl. wrong-path fetch, ref-model scoreboard, SVA, covergroups | `tb/uvm/bp` |
| UVM core | golden-trace scoreboard, branch-resolution checks, perf-counter cross-check, SVA, coverage | `tb/uvm/core` |
| FPGA | on-board demo reads the HW performance counters and shows accuracy on LEDs | `sw/demo`, `fpga/` |

See [docs/verification.md](docs/verification.md) for the plan, coverage model and status.

### Status / honesty notes

* The **RTL, Python flow, SV model check and all regressions** run in CI with Verilator.
* The **UVM environments** are written for UVM 1.2 and are verified to *elaborate cleanly* with the open-source
  slang front end against Accellera's UVM source (`make slang-bp slang-core`). They need a UVM-capable simulator
  (Vivado xsim, Questa, VCS, Xcelium) to *run*. The reference model they use is the same class that is
  proven against the RTL under Verilator, which de-risks the scoreboard.
* The **Vivado/FPGA scripts** were not run in the authoring environment (no Vivado available): check the pin
  names in `fpga/nexys_a7.xdc` against your board revision, and report the achieved WNS/utilization from your run.

## License

MIT, see [LICENSE](LICENSE).
