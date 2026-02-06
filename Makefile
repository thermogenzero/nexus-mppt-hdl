# =============================================================================
# nexus-mppt-hdl Build System
# =============================================================================
# Target: Lattice Nexus 40K (LIFCL-40)
# Toolchain:
#   Simulation  — iverilog + vvp
#   Synthesis   — Yosys (synth_nexus)
#   Place&Route — nextpnr-nexus (Project Oxide / prjoxide)
#   Bitstream   — prjoxide pack
#   Programming — openFPGALoader
# =============================================================================

PROJ = nexus_mppt
TOP  = top

# Target device (Lattice CrossLink-NX / Nexus family)
# LIFCL-40: 40K LUTs, -9 speed, BG400 package, C commercial temp
DEVICE ?= LIFCL-40-9BG400C

# Tool paths (override with environment or command line)
YOSYS         ?= $(shell which yosys 2>/dev/null)
NEXTPNR       ?= $(shell which nextpnr-nexus 2>/dev/null)
PRJOXIDE      ?= $(shell which prjoxide 2>/dev/null)
IVERILOG      ?= $(shell which iverilog 2>/dev/null)
VVP           ?= $(shell which vvp 2>/dev/null)
OPENFPGALOADER ?= $(shell which openFPGALoader 2>/dev/null)
VERILATOR     ?= $(shell which verilator 2>/dev/null)

# Source files
RTL_DIR = rtl
TB_DIR  = tb

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

test-update: $(TB_DIR)/update_tb.v $(UPDATE_SRC) $(SAFETY_SRC) | build
	@echo "=== Running Update Subsystem Testbench ==="
	$(IVERILOG) -g2012 -Wall -o build/update_tb.vvp \
		-I$(RTL_DIR)/update -I$(RTL_DIR)/safety \
		$^
	$(VVP) build/update_tb.vvp
	@echo "=== Update Tests Complete ==="

test-mppt:
	@echo "Phase 4: MPPT testbench not yet implemented"

test-povc:
	@echo "Phase 2: PoVC testbench not yet implemented"

test-system: $(TB_DIR)/system_tb.v $(ALL_SRC) | build
	@echo "=== Running System Testbench ==="
	$(IVERILOG) -g2012 -Wall -o build/system_tb.vvp \
		-I$(RTL_DIR) \
		$^
	$(VVP) build/system_tb.vvp

# =============================================================================
# Lint (Verilator)
# =============================================================================

lint: $(ALL_SRC)
	$(VERILATOR) --lint-only -Wall $(ALL_SRC)

# =============================================================================
# Synthesis (Yosys — synth_nexus)
# =============================================================================
# Yosys targets the Nexus/CrossLink-NX family via synth_nexus, which outputs
# a JSON netlist consumed by nextpnr-nexus.

.PHONY: synthesis pnr bitstream program

synthesis: build/$(PROJ).json
	@echo "=== Synthesis Complete ==="
	@echo "  Device:  $(DEVICE)"
	@echo "  Netlist: build/$(PROJ).json"

build/$(PROJ).json: $(ALL_SRC) | build
	$(YOSYS) -p "\
		read_verilog $(ALL_SRC); \
		synth_nexus -top $(TOP) -json $@" \
		2>&1 | tee build/yosys.log

# =============================================================================
# Place & Route (nextpnr-nexus — Project Oxide)
# =============================================================================
# nextpnr-nexus uses the prjoxide database for Lattice Nexus bitstream
# documentation.  Output is FASM (FPGA Assembly), converted to bitstream
# by prjoxide pack.

pnr: build/$(PROJ).fasm
	@echo "=== Place & Route Complete ==="

build/$(PROJ).fasm: build/$(PROJ).json $(LPF) | build
	$(NEXTPNR) \
		--device $(DEVICE) \
		--json   build/$(PROJ).json \
		--lpf    $(LPF) \
		--fasm   $@ \
		2>&1 | tee build/nextpnr.log

# =============================================================================
# Bitstream Generation (prjoxide pack)
# =============================================================================

bitstream: build/$(PROJ).bit
	@echo "=== Bitstream Generated ==="
	@echo "  File: build/$(PROJ).bit"

build/$(PROJ).bit: build/$(PROJ).fasm | build
	$(PRJOXIDE) pack $< $@

# =============================================================================
# Programming (openFPGALoader)
# =============================================================================

program: build/$(PROJ).bit
	$(OPENFPGALOADER) --bitstream $<

program-flash: build/$(PROJ).bit
	$(OPENFPGALOADER) --write-flash $<

# =============================================================================
# Full build pipeline
# =============================================================================

all: test synthesis pnr bitstream
	@echo ""
	@echo "=== Full Build Complete ==="
	@echo "  Tests:     PASSED"
	@echo "  Bitstream: build/$(PROJ).bit"

# =============================================================================
# Waveform viewer (GTKWave)
# =============================================================================

waves: build/update_tb.vcd
	gtkwave $< &

# =============================================================================
# Utility
# =============================================================================

build:
	@mkdir -p build

clean:
	rm -rf build/*.vvp build/*.vcd build/*.json build/*.fasm build/*.bit build/*.log

.DEFAULT_GOAL := test
