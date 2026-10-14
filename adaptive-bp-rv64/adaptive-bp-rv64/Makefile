# -----------------------------------------------------------------------------
# Adaptive branch prediction for a 64-bit RISC-V core -- project Makefile
#   make help
# -----------------------------------------------------------------------------
PYTHON    ?= python3
SIM       ?=                         # verilator | xsim | questa  (auto-detected when empty)
SIMOPT     = $(if $(SIM),--simulator $(SIM),)
UVM_SRC   ?= $(HOME)/uvm-core/src    # only for `make slang-*` (git clone accellera-official/uvm-core)
N         ?= 40                      # random programs
PTYPE     ?= 3                       # 0 none, 1 bimodal, 2 gshare, 3 tournament

.PHONY: help lint unit test random bench sweep regress model-check slang-bp slang-core \
        uvm-bp uvm-core fpga-hex fpga-build fpga-program clean

help:
	@echo "lint        Verilator -Wall lint of the RTL"
	@echo "unit        pytest unit tests of the Python tool chain"
	@echo "test        directed self-checking programs on every predictor"
	@echo "random      N constrained-random programs, RTL vs golden ISS      (N=$(N))"
	@echo "bench       benchmark sweep over predictors -> results/"
	@echo "sweep       table-size design-space sweep"
	@echo "regress     lint + unit + test + random + bench + model-check"
	@echo "model-check Verilator equivalence check: RTL predictor vs SV reference model"
	@echo "slang-bp/-core  elaborate the UVM benches with open-source slang (needs UVM_SRC)"
	@echo "uvm-bp/-core    run the UVM benches on xsim/Questa (licensed/installed simulator)"
	@echo "fpga-hex    assemble the FPGA demo -> fpga/program.hex"
	@echo "fpga-build  Vivado batch build for the Nexys A7   (PTYPE=$(PTYPE))"
	@echo "fpga-program  program the board over JTAG"

lint:
	verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM --top-module rv64_soc -f rtl/filelist.f

unit:
	$(PYTHON) -m pytest python/tests -q

test:
	$(PYTHON) python/run_flow.py $(SIMOPT) test --all-predictors

random:
	$(PYTHON) python/run_flow.py $(SIMOPT) random -n $(N)

bench:
	$(PYTHON) python/run_flow.py $(SIMOPT) bench --out results

sweep:
	$(PYTHON) python/run_flow.py $(SIMOPT) sweep --benchmark bench_mix --out results

model-check:
	@for p in 0 1 2 3; do \
	  verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style --top-module tb_bp_model_check \
	    -Mdir build/vl_mc$$p -GPREDICTOR_TYPE=$$p -f rtl/filelist.f -Itb tb/tb_bp_model_check.sv -o V >/dev/null && \
	  ./build/vl_mc$$p/V +CYCLES=200000 | grep -E "MODEL_CHECK|PASS|FAIL|MISMATCH" || exit 1; \
	done

regress: lint unit model-check
	$(PYTHON) python/run_flow.py $(SIMOPT) regress -n $(N) --out results

slang-bp:
	$(PYTHON) scripts/slang_check.py bp --uvm $(UVM_SRC)

slang-core:
	$(PYTHON) scripts/slang_check.py core --uvm $(UVM_SRC)

uvm-bp:
	$(PYTHON) python/uvm_flow.py $(SIMOPT) bp --test bp_directed_test --ptype $(PTYPE)
	$(PYTHON) python/uvm_flow.py $(SIMOPT) bp --test bp_random_test   --ptype $(PTYPE) --seeds 5
	$(PYTHON) python/uvm_flow.py $(SIMOPT) bp --test bp_stress_test   --ptype $(PTYPE) --seeds 3

uvm-core:
	$(PYTHON) python/uvm_flow.py $(SIMOPT) core --ptype $(PTYPE) --random $(N)

fpga-hex:
	PYTHONPATH=python $(PYTHON) -m rvtools.asm sw/demo/fpga_demo.s -o fpga/program.hex --listing build/fpga_demo.lst

fpga-build: fpga-hex
	vivado -mode batch -source fpga/build.tcl -tclargs $(PTYPE) $(CURDIR)/fpga/program.hex

fpga-program:
	vivado -mode batch -source fpga/program.tcl -tclargs build/fpga/p$(PTYPE)/top_nexys_a7_p$(PTYPE).bit

clean:
	rm -rf build results/*.png
