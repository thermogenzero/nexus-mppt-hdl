# =============================================================================
# nexus-mppt-hdl Build System
# =============================================================================
# Target: Lattice Nexus 40K (LIFCL-40)
# Toolchain: Lattice Radiant + open-source (Yosys/nextpnr) for simulation
# =============================================================================

PROJ = nexus_mppt
TOP = top

# Toolchain selection
RADIANT ?= 1
YOSYS  ?= $(shell which yosys 2>/dev/null)
IVERILOG ?= $(shell which iverilog 2>/dev/null)

# Source files
RTL_DIR = rtl
TB_DIR = tb

UPDATE_SRC = \
	$(RTL_DIR)/update/bitstream_rx.v \
	$(RTL_DIR)/update/flash_manager.v \
	$(RTL_DIR)/update/ml_dsa87_verify.v \
	$(RTL_DIR)/update/governance.v \
	$(RTL_DIR)/update/watchdog.v \
	$(RTL_DIR)/update/update_top.v

SAFETY_SRC = \
	$(RTL_DIR)/safety/overvoltage.v \
	$(RTL_DIR)/safety/ground_fault.v

TOP_SRC = $(RTL_DIR)/top.v

ALL_SRC = $(UPDATE_SRC) $(SAFETY_SRC) $(TOP_SRC)

# Constraint file
LPF = constraints/nexus40k.lpf

# =============================================================================
# Simulation (iverilog + vvp)
# =============================================================================

.PHONY: test test-update test-safety test-system lint clean

test: test-update

test-update: $(TB_DIR)/update_tb.v $(UPDATE_SRC) $(SAFETY_SRC)
	@echo "=== Running Update Module Testbench ==="
	iverilog -g2012 -Wall -o build/update_tb.vvp \
		-I$(RTL_DIR)/update -I$(RTL_DIR)/safety \
		$^
	vvp build/update_tb.vvp
	@echo "=== Update Tests Complete ==="

test-mppt:
	@echo "Phase 4: MPPT testbench not yet implemented"

test-povc:
	@echo "Phase 2: PoVC testbench not yet implemented"

test-system: $(TB_DIR)/system_tb.v $(ALL_SRC)
	@echo "=== Running System Testbench ==="
	iverilog -g2012 -Wall -o build/system_tb.vvp \
		-I$(RTL_DIR) \
		$^
	vvp build/system_tb.vvp

# =============================================================================
# Lint (Verilator)
# =============================================================================

lint: $(ALL_SRC)
	verilator --lint-only -Wall $(ALL_SRC)

# =============================================================================
# Synthesis (Lattice Radiant)
# =============================================================================

.PHONY: synthesis pnr bitstream program

synthesis: build/$(PROJ).vm
	@echo "=== Synthesis Complete ==="

pnr: build/$(PROJ)_pnr.udb
	@echo "=== Place & Route Complete ==="

bitstream: build/$(PROJ).bit
	@echo "=== Bitstream Generated ==="

build/$(PROJ).vm: $(ALL_SRC) $(LPF)
	@mkdir -p build
	cd build && radiantc ../scripts/build.tcl

build/$(PROJ)_pnr.udb: build/$(PROJ).vm
	cd build && radiantc ../scripts/pnr.tcl

build/$(PROJ).bit: build/$(PROJ)_pnr.udb
	cd build && radiantc ../scripts/bitgen.tcl

program: build/$(PROJ).bit
	python3 scripts/program.py --bitstream $< --device nexus40k

# =============================================================================
# Utility
# =============================================================================

build:
	@mkdir -p build

clean:
	rm -rf build/*.vvp build/*.vcd build/*.vm build/*.udb build/*.bit

.DEFAULT_GOAL := test
