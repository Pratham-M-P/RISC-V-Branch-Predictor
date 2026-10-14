# FPGA validation (AMD Vivado, Nexys A7-100T)

## Build
```
make fpga-build PTYPE=3        # 0 none, 1 bimodal, 2 gshare, 3 tournament
```
`fpga/build.tcl` creates the project, synthesises, implements, writes the bitstream and reports into
`build/fpga/p<PTYPE>/` (`utilization_*.rpt`, `timing_summary.rpt`, `power.rpt`). It exits non-zero if setup/hold
timing is not met. The core runs at 50 MHz (MMCM from the 100 MHz board clock; change `CORE_CLK_DIV`).

The program ROM is initialised from `fpga/program.hex` through the `IMEM_INIT` generic (absolute path, set by the
script); regenerate with `make fpga-hex` or assemble your own program with `python -m rvtools.asm`.

## Program the board
```
make fpga-program PTYPE=3
```

## Using the demo
The demo (`sw/demo/fpga_demo.s`) runs ~340k instructions (a few milliseconds), reads the hardware performance
counters through MMIO and shows the conditional-branch accuracy.

| Switches `SW[2:0]` | LEDs show |
|---|---|
| 000 | GPIO: `LED15` = done, `LED[7:0]` = accuracy % (binary) |
| 001 | conditional mispredicts [15:0] |
| 010 | conditional branches [15:0] |
| 011 / 100 | cycles [15:0] / [31:16] |
| 101 / 110 | instructions retired [15:0] / [31:16] |
| 111 | `LED15` = halted, `LED14` = illegal |

`SW[15]` or the CPU_RESET button restarts the program. Reference values from simulation (tournament):
accuracy = 85 % (`0x55`), cond branches = 80086, mispredicts = 11345, cycles = 364290. Build with different
`PTYPE`s and compare the mispredict counts on the board against `python/run_flow.py` results - this is the
hardware cross-check of the simulation numbers.

## Notes
* Predictor tables and register file map to distributed RAM (asynchronous read ports); expect low LUT usage and no BRAM.
* Check `fpga/nexys_a7.xdc` pins against the Digilent master XDC of your board revision.
* The flow was not executed in the authoring environment; add your utilization/timing numbers to the README table once built.
