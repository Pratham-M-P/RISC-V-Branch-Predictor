# Architecture

## Pipeline and predictor integration

```
        +-----------------------------------------------------------+
        |                branch_predictor                           |
 pc_q --+--> BTB (hit,type,target) --+                              |
        |--> bimodal  --+             |   pred_taken / pred_target   |
        |--> gshare ----+--> choice --+--------------------------+   |
        |        ^ GHR (speculative)  |   pred_meta -> pipeline  |   |
        |--> RAS top -----------------+                          |   |
        +-----------------------------^--------------------------+---+
                                      | bp_update_t (EX)         |
 IF --> ID --> EX ---------------------+                          v
              |  resolve: actual next-PC vs predicted next-PC -> flush IF/ID + ID/EX, redirect PC
              +--> MEM --> WB
```

* `PC` register feeds the predictor combinationally; the instruction memory is asynchronous so the predicted
  next-PC is available in the same cycle (no fetch bubble for correctly predicted taken branches).
* The predictor returns `bp_meta_t`: `{ghr[15:0], bim_taken, gsh_taken, dir_taken, ras_ptr[3:0]}`. It is stored in
  IF/ID and ID/EX and returned in `bp_update_t` at resolution.

## Predictor components

| Block | Parameters (defaults) | Notes |
|---|---|---|
| `bp_btb` | `BTB_IDX_W=6` (64 entries), `BTB_TAG_W=16` | direct mapped; allocate on *taken*; invalidate on alias onto non-branch |
| bimodal | `BIM_IDX_W=10` | 2-bit counters, init weakly-not-taken |
| gshare | `GSH_IDX_W=10` (= history length) | index = `pc[W+1:2] ^ GHR` |
| choice | `CHO_IDX_W=10` | MSB=1 selects gshare; trained only when bimodal != gshare; moves toward the correct one |
| `bp_ras` | `RAS_DEPTH=8` | circular; pointer checkpoint in meta; recovery re-applies the actual push/pop |

### Update rules
* **Training** (every resolved conditional branch): both component counters, using the *fetch-time* GHR snapshot
  from the metadata so training hits the entry that produced the prediction.
* **GHR**: shifts at fetch only for conditional branches that hit in the BTB. On mispredict it is rebuilt as
  `snapshot` (+ actual outcome if the resolved instruction is a conditional branch). Branches never seen taken
  therefore never enter the history, and the rule is consistent between speculative and recovered paths.
* **RAS**: push on predicted CALL, pop on predicted RET (fetch); on mispredict the pointer is restored from the
  checkpoint and the *actual* effect (push for call, pop for return) applied.
* **Mispredict** = `(fetched next-PC) != (actual next-PC)`. Also fires for taken predictions on non-branch instructions.

## Core
* RV64I base: all ALU/W-forms, loads/stores of every width, LUI/AUIPC/JAL/JALR/branches, FENCE (nop), ECALL/EBREAK (halt).
* Hazards: full forwarding EX/MEM->EX and MEM/WB->EX, register file write-through, 1-cycle load-use stall.
* Halt: ECALL/EBREAK/illegal reaching EX stops fetch and squashes younger instructions; `halted_o` rises at commit.
* Memories: Harvard. Instruction ROM/RAM 16 KiB (`IMEM_AW=12`), data RAM 16 KiB (`DMEM_AW=11`). Unused instruction
  words contain ECALL.

## Memory map (data side)

| Address | Meaning |
|---|---|
| `0x0000_0000`-`0x0000_3FFF` | data RAM |
| `0x8000_0000` | GPIO out (R/W) -> LEDs |
| `0x8000_0010/18/20/28/30/38` | cycles / instret / cond branches / cond mispredicts / ctrl-flow / ctrl-flow mispredicts (RO) |

## Performance counters
`perf_cond_br`, `perf_cond_mispred` (conditional branches), `perf_ctrl*` (all control flow), `perf_cycles`,
`perf_instret`. Accuracy = `1 - cond_mispred / cond_br`.

## Extending
* Larger/associative BTB: replace `bp_btb`, interface is lookup/write only.
* Other predictors (TAGE, perceptron): add a component next to gshare and extend `bp_meta_t`; the scoreboard model
  (`bp_ref_model`) is the single place to mirror the behaviour.
* M extension: extend `rv64_decoder`/`rv64_alu`; the ISS and assembler need the same additions.
