IVERILOG ?= iverilog
VVP ?= vvp
PYTHON ?= python3
ROWS ?= 64
COLS ?= 64
SEED ?= 20261029
JOBS ?= 20
TRIALS ?= 3
BUILD_DIR := build
RTL := rtl/axis_int8_matvec.sv
TB := sim/tb_axis_int8_matvec.sv
SIM := $(BUILD_DIR)/matvec_$(ROWS)x$(COLS).vvp
CTRL := rtl/matvec_axil_ctrl.sv
TOP := rtl/kv260_matvec.sv
BFM := sim/axil_master_bfm.sv sim/axil_signals.svh
CTRL_SIM := $(BUILD_DIR)/axil_control.vvp
PERIPHERAL_SIM := $(BUILD_DIR)/peripheral_$(ROWS)x$(COLS).vvp
DMA_MODELS := sim/models/s2mm_write_model.sv sim/models/axi_write_ram_model.sv sim/models/axi_write_checker.sv
DMA_SIGNALS := sim/models/axi_write_signals.svh
REUSE_SIM := $(BUILD_DIR)/reuse_$(ROWS)x$(COLS).vvp
DMA_MODEL_SIM := $(BUILD_DIR)/dma_models.vvp
STALE_SIM := $(BUILD_DIR)/stale_$(ROWS)x$(COLS).vvp
VIVADO ?= vivado
DOCKER ?= docker
UI_PORT ?= 8080
NODE ?= node

.PHONY: test test-core test-control test-peripheral test-dma-models test-reuse test-stale report-reuse test-matrix compile wave clean host-test linux-test vivado-project vivado-build ui ui-test

compile: $(SIM) $(CTRL_SIM) $(PERIPHERAL_SIM) $(DMA_MODEL_SIM) $(REUSE_SIM) $(STALE_SIM)

$(SIM): $(RTL) $(TB) Makefile
	@mkdir -p $(BUILD_DIR)
	$(IVERILOG) -g2012 -Wall -s tb_axis_int8_matvec \
		-Ptb_axis_int8_matvec.ROWS=$(ROWS) -Ptb_axis_int8_matvec.COLS=$(COLS) \
		-o $@ $(RTL) $(TB)

test: test-core test-control test-peripheral test-dma-models test-reuse test-stale

test-core: $(SIM)
	$(VVP) $(SIM) +SEED=$(SEED) +JOBS=$(JOBS)

$(CTRL_SIM): $(CTRL) $(BFM) sim/tb_matvec_axil_ctrl.sv Makefile
	@mkdir -p $(BUILD_DIR)
	$(IVERILOG) -g2012 -Wall -I sim -s tb_matvec_axil_ctrl \
		-o $@ $(CTRL) sim/axil_master_bfm.sv sim/tb_matvec_axil_ctrl.sv

test-control: $(CTRL_SIM)
	$(VVP) $(CTRL_SIM)

$(PERIPHERAL_SIM): $(RTL) $(CTRL) $(TOP) $(BFM) sim/tb_kv260_matvec.sv Makefile
	@mkdir -p $(BUILD_DIR)
	$(IVERILOG) -g2012 -Wall -I sim -s tb_kv260_matvec \
		-Ptb_kv260_matvec.ROWS=$(ROWS) -Ptb_kv260_matvec.COLS=$(COLS) \
		-o $@ $(RTL) $(CTRL) $(TOP) sim/axil_master_bfm.sv sim/tb_kv260_matvec.sv

test-peripheral: $(PERIPHERAL_SIM)
	$(VVP) $(PERIPHERAL_SIM) +SEED=$(SEED)

$(REUSE_SIM): $(RTL) $(CTRL) $(TOP) $(BFM) $(DMA_MODELS) $(DMA_SIGNALS) sim/tb_dma_buffer_reuse.sv Makefile
	@mkdir -p $(BUILD_DIR)
	$(IVERILOG) -g2012 -Wall -I sim -I sim/models -s tb_dma_buffer_reuse \
		-Ptb_dma_buffer_reuse.ROWS=$(ROWS) -Ptb_dma_buffer_reuse.COLS=$(COLS) \
		-o $@ $(RTL) $(CTRL) $(TOP) sim/axil_master_bfm.sv $(DMA_MODELS) sim/tb_dma_buffer_reuse.sv

test-reuse: $(REUSE_SIM)
	$(VVP) $(REUSE_SIM) +SEED=$(SEED) +TRIALS=$(TRIALS)

$(DMA_MODEL_SIM): $(DMA_MODELS) $(DMA_SIGNALS) sim/tb_dma_models.sv Makefile
	@mkdir -p $(BUILD_DIR)
	$(IVERILOG) -g2012 -Wall -I sim/models -s tb_dma_models \
		-o $@ $(DMA_MODELS) sim/tb_dma_models.sv

test-dma-models: $(DMA_MODEL_SIM)
	$(VVP) $(DMA_MODEL_SIM)

$(STALE_SIM): $(RTL) $(DMA_MODELS) $(DMA_SIGNALS) sim/tb_stale_stream.sv Makefile
	@mkdir -p $(BUILD_DIR)
	$(IVERILOG) -g2012 -Wall -I sim/models -s tb_stale_stream \
		-Ptb_stale_stream.ROWS=$(ROWS) -Ptb_stale_stream.COLS=$(COLS) \
		-o $@ $(RTL) $(DMA_MODELS) sim/tb_stale_stream.sv

test-stale: $(STALE_SIM)
	$(VVP) $(STALE_SIM)

report-reuse: test-reuse
	$(IVERILOG) -V > $(BUILD_DIR)/simulator-version.txt 2>&1
	$(PYTHON) scripts/report_reuse.py --inputs $(BUILD_DIR)/reuse_$(ROWS)x$(COLS).jsonl \
		--version-file $(BUILD_DIR)/simulator-version.txt --output-dir results/reuse

test-matrix: test-control test-dma-models
	$(MAKE) test-core test-peripheral test-reuse test-stale ROWS=1 COLS=4
	$(MAKE) test-core test-peripheral test-reuse test-stale ROWS=3 COLS=12
	$(MAKE) test-core test-peripheral test-reuse test-stale ROWS=16 COLS=16
	$(MAKE) test-core test-peripheral test-reuse test-stale ROWS=64 COLS=64
	$(IVERILOG) -V > $(BUILD_DIR)/simulator-version.txt 2>&1
	$(PYTHON) scripts/report_reuse.py --inputs $(BUILD_DIR)/reuse_1x4.jsonl \
		$(BUILD_DIR)/reuse_3x12.jsonl $(BUILD_DIR)/reuse_16x16.jsonl $(BUILD_DIR)/reuse_64x64.jsonl \
		--version-file $(BUILD_DIR)/simulator-version.txt --output-dir results/reuse

wave: $(SIM)
	$(VVP) $(SIM) +SEED=$(SEED) +JOBS=$(JOBS) +VCD

clean:
	rm -rf $(BUILD_DIR)

host-test:
	$(MAKE) -C sw/user test
	$(PYTHON) -m unittest discover -s tests -p 'test_*.py' -v

linux-test:
	$(DOCKER) build -f tests/Dockerfile -t hardware-secx-verify:debian13 tests
	@mkdir -p build/linux
	$(DOCKER) run --rm -v "$(CURDIR):/src:ro" -v "$(CURDIR)/build/linux:/out" \
		hardware-secx-verify:debian13 sh /src/scripts/verify_linux.sh

vivado-project:
	$(VIVADO) -mode batch -source hw/create_project.tcl -tclargs project

vivado-build:
	$(VIVADO) -mode batch -source hw/create_project.tcl -tclargs build

ui:
	$(PYTHON) -m web.server --port $(UI_PORT)

ui-test:
	$(NODE) --check web/static/app.js
	$(NODE) --check web/static/i18n.js
	$(NODE) --test tests/interface_dom.test.mjs
