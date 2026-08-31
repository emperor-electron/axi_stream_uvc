# ==============================================================================
# Makefile for the AXI4-Stream UVC self-test (scaffolded by uvm-tb).
#
# Usage:
#   make                 compile, elaborate, and run TEST in batch mode
#   make TEST=<uvm_test> run a different UVM test
#   make waves           run and dump a waveform database (waves.wdb)
#   make gui             run interactively in the XSIM GUI
#   make clean           remove simulation artifacts
#   make help            show this list of targets
#
# Common overrides (pass on the command line, e.g. `make run SEED=1`):
#   TEST, SEED, UVM_VERBOSITY, WAVES, PLUSARGS, VIVADO_PATH
#
# Available tests (TEST=...):
#   axi_stream_smoke_test         a little traffic, no backpressure
#   axi_stream_multiwidth_test    all five widths, random backpressure  [default]
#   axi_stream_backpressure_test  every built-in ready model, one per link
#   axi_stream_no_ready_test      TREADY held low, then released
#   axi_stream_sparse_test        null/position byte payloads
#   axi_stream_reset_test         ARESETn pulsed mid-traffic
#   make regress                  runs all of the above in turn
#
# The UVC itself is compiled through $(UVC_FILELIST) -- the same drop-in
# filelist another project would use -- so this build exercises the UVC's
# packaging, not just its source.
# ==============================================================================

SHELL           := /bin/bash

SIM             ?= xsim
TOP             ?= axi_stream_tb_top
TEST            ?= axi_stream_multiwidth_test
SEED            ?= random
UVM_VERBOSITY   ?= UVM_MEDIUM
FILELIST        ?= filelist.f
EXTRA_FILELIST  ?= extra_files.f

# Root of this repository, so the UVC is pulled in exactly the way a
# consuming project pulls it in. Override to compile against a UVC
# checked out elsewhere.
AXI_STREAM_UVC_ROOT ?= $(abspath $(dir $(lastword $(MAKEFILE_LIST)))..)
export AXI_STREAM_UVC_ROOT
UVC_FILELIST    ?= $(AXI_STREAM_UVC_ROOT)/src/axi_stream_uvc.f
SNAPSHOT        ?= $(TOP)_snap
WAVES           ?= 0
PLUSARGS        ?=
SIM_LOG         ?= sim.log

# A UVM_FATAL/UVM_ERROR run still exits xsim with status 0 (it called
# $finish, not a crash), so `run`/`waves` below tee the simulation log and
# grep it for the top module's own "result : FAILED" banner line instead,
# so a failing test actually fails the `make` invocation too (for CI).
CHECK_PASS = ! grep -q '^ result  : FAILED$$' $(SIM_LOG)

# ------------------------------------------------------------------------------
# Per-simulator setup. Add another `else ifeq` block here to support more
# simulators (Questa, VCS, Xcelium, ...); everything below this block is
# written to be simulator-agnostic.
# ------------------------------------------------------------------------------
ifeq ($(SIM),xsim)
  # No fixed Vivado install was given at generate-time, so pick the
  # highest-sorting version directory under VIVADO_BASE, e.g.
  # /tools/Xilinx/Vivado/2023.2. Override either on the command line:
  #   make VIVADO_PATH=/tools/Xilinx/Vivado/2023.2 ...
  VIVADO_BASE    ?= /tools/Xilinx/Vivado
  VIVADO_VERSION ?= $(notdir $(lastword $(sort $(wildcard $(VIVADO_BASE)/*))))
  VIVADO_PATH    ?= $(VIVADO_BASE)/$(VIVADO_VERSION)
  VIVADO_SETTINGS := $(VIVADO_PATH)/settings64.sh
  VIVADO_ENV      := source $(VIVADO_SETTINGS) >/dev/null &&

  XVLOG_BIN      ?= xvlog
  XELAB_BIN      ?= xelab
  XSIM_BIN       ?= xsim
  UVM_LIB        ?= uvm

  XVLOG_FLAGS    := -sv -L $(UVM_LIB)
  # --override_time{unit,precision} force one consistent timescale across
  # the whole design, since xelab errors out on a mix of modules with and
  # without an explicit `timescale (which the DUT may or may not declare).
  XELAB_FLAGS    := -L $(UVM_LIB) --timescale 1ns/1ps --override_timeunit --override_timeprecision
  ifeq ($(WAVES),1)
    XELAB_FLAGS  += -debug all
  else
    XELAB_FLAGS  += -debug typical
  endif
  RUN_FLAGS      := -sv_seed $(SEED) -testplusarg "UVM_TESTNAME=$(TEST)" -testplusarg "UVM_VERBOSITY=$(UVM_VERBOSITY)" $(PLUSARGS)
  REQUIRED_TOOLS := $(XVLOG_BIN) $(XELAB_BIN) $(XSIM_BIN)
else
  $(error Unsupported SIM=$(SIM). Supported simulators: xsim)
endif

REGRESS_TESTS ?= axi_stream_smoke_test axi_stream_multiwidth_test \
                 axi_stream_backpressure_test axi_stream_no_ready_test \
                 axi_stream_sparse_test axi_stream_reset_test

CHECK_TOP      ?= axi_stream_if_check_tb
CHECK_SNAPSHOT ?= $(CHECK_TOP)_snap

.PHONY: all compile elab run sim waves gui clean help check-tools regress check-protocol

all: run

check-tools:
	@if [ ! -f "$(VIVADO_SETTINGS)" ]; then \
		echo "error: Vivado settings script not found: $(VIVADO_SETTINGS)"; \
		echo "       Override VIVADO_PATH, e.g.:"; \
		echo "         make VIVADO_PATH=/tools/Xilinx/Vivado/2023.2 ..."; \
		exit 1; \
	fi
	@$(VIVADO_ENV) ( for t in $(REQUIRED_TOOLS); do \
		command -v $$t >/dev/null 2>&1 || { echo "error: '$$t' not found even after sourcing $(VIVADO_SETTINGS)"; exit 1; }; \
	done )

compile: check-tools
	$(VIVADO_ENV) $(XVLOG_BIN) $(XVLOG_FLAGS) -f $(UVC_FILELIST) -f $(FILELIST) $(if $(wildcard $(EXTRA_FILELIST)),-f $(EXTRA_FILELIST))

elab: compile
	$(VIVADO_ENV) $(XELAB_BIN) $(XELAB_FLAGS) $(TOP) -s $(SNAPSHOT)

run sim: elab
	@set -o pipefail; \
	{ $(VIVADO_ENV) $(XSIM_BIN) $(SNAPSHOT) $(RUN_FLAGS) -R | tee $(SIM_LOG); } && \
	$(CHECK_PASS)

waves: elab
	@set -o pipefail; \
	{ $(VIVADO_ENV) $(XSIM_BIN) $(SNAPSHOT) $(RUN_FLAGS) -wdb waves.wdb -tclbatch wave.tcl | tee $(SIM_LOG); } && \
	$(CHECK_PASS)

gui: elab
	$(VIVADO_ENV) $(XSIM_BIN) $(SNAPSHOT) $(RUN_FLAGS) -gui

# Negative test for the interface's protocol assertions: breaks each rule
# on purpose and fails unless the interface catches it. Worth running
# whenever those assertions are touched -- a checker that stops firing
# makes every other test in here pass for the wrong reason.
check-protocol: compile
	$(VIVADO_ENV) $(XELAB_BIN) $(XELAB_FLAGS) $(CHECK_TOP) -s $(CHECK_SNAPSHOT)
	@set -o pipefail; \
	{ $(VIVADO_ENV) $(XSIM_BIN) $(CHECK_SNAPSHOT) -R | tee check.log; } && \
	! grep -q '^ result  : FAILED$$' check.log

# Every test in turn against one elaborated snapshot. Keeps going after a
# failure so one broken test does not hide the state of the others, then
# fails the target if any of them failed.
regress: elab
	@$(MAKE) --no-print-directory check-protocol
	@set -o pipefail; rc=0; \
	for t in $(REGRESS_TESTS); do \
	  echo "=== $$t ==="; \
	  if { $(VIVADO_ENV) $(XSIM_BIN) $(SNAPSHOT) -sv_seed $(SEED) \
	        -testplusarg "UVM_TESTNAME=$$t" \
	        -testplusarg "UVM_VERBOSITY=$(UVM_VERBOSITY)" $(PLUSARGS) -R \
	        | tee $$t.log; } && ! grep -q '^ result  : FAILED$$' $$t.log; then \
	    echo "--- $$t PASSED"; \
	  else \
	    echo "--- $$t FAILED"; rc=1; \
	  fi; \
	done; \
	echo; echo "regression $$([ $$rc -eq 0 ] && echo PASSED || echo FAILED)"; \
	exit $$rc

clean:
	rm -rf xsim.dir *.wdb *.jou *.log *.pb webtalk* .Xil
	rm -f $(SNAPSHOT).*

help:
	@echo "Targets:"
	@echo "  all (default) - compile, elaborate, and run TEST in batch mode"
	@echo "  compile        - compile sources listed in FILELIST + EXTRA_FILELIST with xvlog"
	@echo "  elab           - elaborate TOP into a simulation snapshot"
	@echo "  run / sim      - build and run TEST to completion, no GUI"
	@echo "  waves          - build and run, dumping a waveform database (waves.wdb)"
	@echo "  gui            - build and run interactively in the XSIM GUI"
	@echo "  regress        - run every test in REGRESS_TESTS against one snapshot"
	@echo "  check-protocol - negative test: prove the protocol assertions fire"
	@echo "  clean          - remove simulation artifacts"
	@echo ""
	@echo "Common overrides: TEST=<uvm_test> SEED=<n> UVM_VERBOSITY=<UVM_*> WAVES=1 VIVADO_PATH=<path>"
	@echo ""
	@echo "Other files needed for simulation (e.g. sub-modules your DUT"
	@echo "instantiates)? List them in $(EXTRA_FILELIST), one per line."
