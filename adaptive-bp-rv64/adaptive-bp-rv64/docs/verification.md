# Verification plan and status

## Strategy
Three independent references check the design at different granularity:

1. **Golden ISS (Python)** - architectural behaviour of the whole core (commit trace).
2. **SV reference model `bp_ref_model`** - cycle-accurate behaviour of the predictor unit.
3. **Assertions** - protocol/pipeline rules that need no reference.

| ID | Feature | Test / checker |
|---|---|---|
| F1 | RV64I arithmetic, shifts, W forms | `sw/directed/test_alu.s` (+ random programs, ISS compare) |
| F2 | loads/stores, byte lanes, MMIO | `test_loadstore.s` |
| F3 | all conditional branches, jal/jalr links | `test_branch.s` |
| F4 | forwarding and load-use stalls | `test_hazard.s` |
| F5 | call/return, recursion, nesting > RAS depth | `test_calls.s`, `bench_fib`, UVM `bp_callret_seq` |
| F6 | BTB aliasing / replacement | `test_btb_alias.s`, UVM `bp_alias_seq` |
| F7 | indirect jumps, changing targets | `test_indirect.s` |
| F8 | illegal instruction halts | `test_illegal.s` |
| F9 | predictor == model for any stimulus | `tb_bp_model_check.sv`, UVM scoreboard |
| F10 | GHR/RAS recovery under wrong-path fetch | UVM driver wrong-path mode, model check recoveries |
| F11 | predictor never alters architecture | all programs run under *every* predictor type with identical commit trace |
| F12 | performance counters consistent | UVM core scoreboard `SB_PERF` checks |

## Python / Verilator regression (`make regress`)
* directed programs x 4 predictor types: self-check result (`a0 == 0`) **and** commit-trace equality with the ISS
* constrained-random programs (3 generator profiles, rotating predictor type)
* benchmarks x 4 predictor types: trace equality + statistics
* `tb_bp_model_check` x 4 predictor types, 200k cycles, small tables to force aliasing and recovery

Last local result: directed 32/32, random 300/300 (seed 1000), benchmarks 24/24, model check 4/4.

## UVM - predictor level (`tb/uvm/bp`)
* **Agent**: sequencer + driver + monitor. The driver emulates the pipeline: fetches the correct-path stream,
  returns the captured metadata `pipe_lat` cycles later, and on a misprediction keeps fetching *wrong-path*
  PCs until the branch resolves, then flushes - this is what stresses speculative-state recovery.
* **Sequences**: directed `bp_loop_seq`, `bp_pattern_seq`, `bp_callret_seq`, `bp_alias_seq`; constrained-random
  `bp_random_seq` (randomised per-PC `bp_site`: kind, bias, periodic pattern, loop trip, targets).
* **Scoreboard**: `bp_ref_model` predicted vs DUT every cycle (taken, target, meta), model advanced with the exact stimulus.
* **Assertions** (`bp_if`): no X, BP_NONE never taken, aligned targets, prediction stable without state-changing events,
  one-hot control types, jumps resolve taken, call/ret exclusive. Cover properties for recover-with-fetch,
  back-to-back mispredicts.
* **Functional coverage** (`bp_coverage`): control kind x taken x mispredict; tournament matrix (components agree / which one
  was right); RAS depth; recover-concurrent-with-fetch; GHR values.
* **Tests**: `bp_directed_test`, `bp_random_test` (`+REPS`, `+NITEMS`), `bp_stress_test`.

## UVM - core level (`tb/uvm/core`)
* Passive monitor on `rv64_soc` taps (commit bus, EX resolution bus, status/perf).
* **Scoreboard**: commit stream vs `+GOLDEN` ISS trace; resolved control-flow vs golden control instructions
  (pc/direction/target); re-derived misprediction flag; end-of-test counters vs performance counters.
* **Assertions** (`core_if`): mispredict flag definition, 2-cycle shadow, no commit after halt, x0 never written,
  well-formed commit bus, monotonic counters.
* **Coverage**: instruction classes x funct3, branch type x predicted x actual, back/forward branches, stall x mispredict.
* Programs come from `python/uvm_flow.py core` (directed, benchmarks, random).

## Running UVM
```
source <Vivado>/settings64.sh
make uvm-bp SIM=xsim
make uvm-core SIM=xsim N=20
```
Pass criterion: `UVM_TEST_RESULT: PASS` and zero `UVM_ERROR/UVM_FATAL`. For Questa, set `SIM=questa`
(check the UVM library flags of your installation in `python/uvm_flow.py`).

## Honest status
The UVM sources compile and elaborate with slang against Accellera UVM; they were not executed in the authoring
environment (no UVM-capable simulator). The reference model and all non-UVM checks were executed. When you first
run on your simulator, expect at most tool-specific tweaks (e.g. library flags).
