# -----------------------------------------------------------------------------
# Common settings -------------------------------------------------------------
# -----------------------------------------------------------------------------

ROOT_DIR = $(realpath $(CURDIR))

# Input settings -------------------------------------------------------------

DOCKER_IMAGE_PREFIX ?= antmicro/
DOCKER_TAG_NAME ?= alkali
DOCKER_TAG ?= $(DOCKER_IMAGE_PREFIX)$(DOCKER_TAG_NAME)

BOARD ?= an300
BAR_SIZE ?= 16MB
BUILD_DIR ?= $(ROOT_DIR)/build
EXAMPLE ?= add
HW_BUILD_DIR ?= $(ROOT_DIR)/build/hardware
FW_BUILD_DIR ?= $(ROOT_DIR)/build/firmware

define UNSUPPORTED_BOARD_MSG
Boards $(BOARD) is not supported, choose one of following:
$(foreach BOARD, $(SUPPORTED_BOARDS),	- $(BOARD)
)
endef

SUPPORTED_BOARDS = zcu106 an300
ifneq '$(BOARD)' '$(findstring $(BOARD),$(SUPPORTED_BOARDS))'
$(error $(UNSUPPORTED_BOARD_MSG))
endif

# Input paths -----------------------------------------------------------------

HW_ROOT_DIR = $(ROOT_DIR)/alkali-csd-hw
FW_ROOT_DIR = $(ROOT_DIR)/alkali-csd-fw
FW_THIRD_PARTY_DIR = $(FW_ROOT_DIR)/third-party
REGGEN_DIR = $(FW_THIRD_PARTY_DIR)/registers-generator
TENSORFLOW_DIR = $(FW_THIRD_PARTY_DIR)/tensorflow
BOARD_DIR = $(ROOT_DIR)/boards/$(BOARD)
EXAMPLE_DIR = $(ROOT_DIR)/examples/tflite_vta/$(EXAMPLE)
HOSTAPP_DIR = $(ROOT_DIR)/host-app
FW_WEST_YML = $(FW_ROOT_DIR)/rpu-app/west.yml
WEST_CONFIG = $(ROOT_DIR)/.west/config
WEST_INIT_DIR = $(ROOT_DIR)

# Output paths ----------------------------------------------------------------

BOARD_BUILD_DIR = $(BUILD_DIR)/$(BOARD)
BUILDROOT_BUILD_DIR = $(BUILD_DIR)/firmware/buildroot/images
HOSTAPP_BUILD_DIR = $(BUILD_DIR)/host-app
EXAMPLE_BUILD_DIR = $(BUILD_DIR)/examples/$(EXAMPLE)
WEST_YML = $(FW_BUILD_DIR)/rpu-app/west.yml

# Helpers  --------------------------------------------------------------------

HW_MAKE_OPTS = BUILD_DIR=$(HW_BUILD_DIR) BAR_SIZE=$(BAR_SIZE)
FW_MAKE_OPTS = BUILD_DIR=$(FW_BUILD_DIR) WEST_CONFIG=$(WEST_CONFIG) \
	       WEST_YML=$(WEST_YML) WEST_INIT_DIR=$(BUILD_DIR)

# Board-specific settings -----------------------------------------------------

-include $(BOARD_DIR)/board.mk

ifndef BOARD_SDCARD_CONTENTS
$(error BOARD_SDCARD_CONTENTS is not set. Please update board.mk file in the $(BOARD_DIR) directory)
endif

ifndef BOARD_DTB_NAME
$(error BOARD_DTB_NAME is not set. Please update board.mk file in the $(BOARD_DIR) directory)
endif


# -----------------------------------------------------------------------------
# All -------------------------------------------------------------------------
# -----------------------------------------------------------------------------

.PHONY: all
all: sdcard ## Build all system components for the specified board

# -----------------------------------------------------------------------------
# Clean -----------------------------------------------------------------------
# -----------------------------------------------------------------------------

.PHONY: clean
clean: ## Remove ALL build artifacts
	$(RM) -r $(BUILD_DIR)
	$(RM) -r $(ROOT_DIR)/.west

# -----------------------------------------------------------------------------
# Firmware --------------------------------------------------------------------
# -----------------------------------------------------------------------------

.PHONY: firmware/all
firmware/all: $(WEST_YML) ## Build all Firmware binaries (Buildroot, APU App, RPU App)
	$(MAKE) -C $(FW_ROOT_DIR) $(FW_MAKE_OPTS) all

.PHONY: firmware/clean
firmware/clean: ## Remove ALL Firmware build artifacts
	$(MAKE) -C $(FW_ROOT_DIR) $(FW_MAKE_OPTS) clean

# Firmware rule forwarding depends on $(WEST_YML) to make sure that
# all zephyr and rpu-app targets work correctly
.PHONY: firmware//%
firmware//%: $(WEST_YML) ## Forward rule to invoke firmware rules directly e.g. `make firmware//apu-app`, `make firmware//buildroot//menuconfig`
	$(MAKE) -C $(FW_ROOT_DIR) $(FW_MAKE_OPTS) $*

$(WEST_YML): # Generate west.yml based on manifest from Firmware repository
	mkdir -p $(FW_BUILD_DIR)/rpu-app
	sed -e 's/path: build/path: build\/firmware/g' \
		-e 's/rpu-app/alkali-csd-fw\/rpu-app/g' $(FW_WEST_YML) > $(WEST_YML)

# -----------------------------------------------------------------------------
# Hardware --------------------------------------------------------------------
# -----------------------------------------------------------------------------

.PHONY: hardware/all
hardware/all: ## Build all Hardware binaries (Vivado design)
	$(MAKE) -C $(HW_ROOT_DIR) $(HW_MAKE_OPTS) all

.PHONY: hardware/clean
hardware/clean:
	$(MAKE) -C $(HW_ROOT_DIR) $(HW_MAKE_OPTS) clean

.PHONY: hardware//%
hardware//%: ## Forward rule to invoke hardware rules directly e.g. `make hardware//chisel`
	$(MAKE) -C $(HW_ROOT_DIR) $(HW_MAKE_OPTS) $*

# -----------------------------------------------------------------------------
# Build boot image ------------------------------------------------------------
# -----------------------------------------------------------------------------

$(BOARD_BUILD_DIR):
	mkdir -p $@

BOOTBIN_BUILD_DIR = $(BOARD_BUILD_DIR)/bootbin
$(BOOTBIN_BUILD_DIR):
	mkdir -p $@

SYSTEM_DTB = $(BUILDROOT_BUILD_DIR)/$(BOARD_DTB_NAME)
ROOTFS_CPIO = $(BUILDROOT_BUILD_DIR)/rootfs.cpio.uboot
LINUX_IMAGE = $(BUILDROOT_BUILD_DIR)/Image
BL31_ELF = $(BUILDROOT_BUILD_DIR)/bl31.elf
U_BOOT_ELF = $(BUILDROOT_BUILD_DIR)/u-boot.elf

TOP_BIT = $(HW_BUILD_DIR)/$(BOARD)/project_vta/out/top.bit
TOP_XSA = $(HW_BUILD_DIR)/$(BOARD)/project_vta/out/top.xsa

BOOT_SCR = $(BOARD_BUILD_DIR)/boot.scr
BOOT_BIF = $(BOARD_DIR)/boot.bif
BOOT_CMD = $(BOARD_DIR)/boot.cmd
BOOT_BIN = $(BOOTBIN_BUILD_DIR)/boot.bin
FSBL_ELF = $(BOOTBIN_BUILD_DIR)/fsbl.elf
PMU_ELF = $(BOOTBIN_BUILD_DIR)/pmufw.elf

$(BOOT_BIN): hardware/all
$(BOOT_BIN): firmware/all
$(BOOT_BIN): $(BOOT_SCR)
$(BOOT_BIN): $(PMU_ELF)
$(BOOT_BIN): $(FSBL_ELF)
$(BOOT_BIN): | $(BOOTBIN_BUILD_DIR)
	stat $(FSBL_ELF) $(PMU_ELF) # already in the build directory (check `make fsbl`, `make pmufw`)
	cp $(TOP_BIT) $(BOOTBIN_BUILD_DIR)/.
	cp $(SYSTEM_DTB) $(BOOTBIN_BUILD_DIR)/system.dtb
	cp $(BL31_ELF) $(BOOTBIN_BUILD_DIR)/.
	cp $(U_BOOT_ELF) $(BOOTBIN_BUILD_DIR)/.
	cp $(LINUX_IMAGE) $(BOOTBIN_BUILD_DIR)/.
	cp $(ROOTFS_CPIO) $(BOOTBIN_BUILD_DIR)/.
	cp $(BOOT_SCR) $(BOOTBIN_BUILD_DIR)/.
	cd $(BOOTBIN_BUILD_DIR) && mkbootimage --zynqmp $(BOOT_BIF) $(BOOT_BIN)

.PHONY: boot-image
boot-image: $(BOOT_BIN) ## Build boot.bin

$(BOOT_SCR): $(BOOT_CMD)
	mkimage -c none -A arm -T script -d $(BOOT_CMD) $(BOOT_SCR)

# -----------------------------------------------------------------------------
# FSBL and PMUFW --------------------------------------------------------------
# -----------------------------------------------------------------------------

$(FSBL_ELF): hardware/all
	BUILD_DIR=$(BOOTBIN_BUILD_DIR) XSA_FILE=$(TOP_XSA) make -C $(BOARD_DIR) fsbl

.PHONY: fsbl
fsbl: $(FSBL_ELF)

$(PMU_ELF): hardware/all
	BUILD_DIR=$(BOOTBIN_BUILD_DIR) XSA_FILE=$(TOP_XSA) make -C $(BOARD_DIR) pmufw

.PHONY: pmufw
pmufw: $(PMU_ELF)

# -----------------------------------------------------------------------------
# SDCARD ----------------------------------------------------------------------
# -----------------------------------------------------------------------------

SDCARD_BUILD_DIR = $(BOARD_BUILD_DIR)/sdcard
$(SDCARD_BUILD_DIR):
	mkdir -p $@

SDCARD_OUTPUTS = $(addprefix $(SDCARD_BUILD_DIR)/, $(BOARD_SDCARD_CONTENTS))
SDCARD_FILES = $(addprefix $(BOOTBIN_BUILD_DIR)/, $(BOARD_SDCARD_CONTENTS))

$(SDCARD_OUTPUTS) &: $(BOOT_BIN) | $(SDCARD_BUILD_DIR)
	cp $(SDCARD_FILES) $(SDCARD_BUILD_DIR)/.

sdcard: $(SDCARD_OUTPUTS) ## Create build directory with SD card contents

# -----------------------------------------------------------------------------
#  HOST APP -------------------------------------------------------------------
# -----------------------------------------------------------------------------

HOSTAPP_OUTPUTS = $(HOSTAPP_BUILD_DIR)/host-app $(HOSTAPP_BUILD_DIR)/tf-app
HOSTAPP_SOURCES = $(wildcard $(HOSTAPP_DIR)/src/*.cpp) \
		   $(wildcard $(HOSTAPP_DIR)/src/*.h)

.PHONY: host-app
host-app: $(HOSTAPP_OUTPUTS) ## Build host app

$(HOSTAPP_BUILD_DIR):
	@mkdir -p $@

$(HOSTAPP_OUTPUTS) &: $(HOSTAPP_SOURCES) | $(HOSTAPP_BUILD_DIR)
	@cmake \
		-DTENSORFLOW_SOURCE_DIR=$(TENSORFLOW_DIR) \
		-S $(HOSTAPP_DIR) -B $(HOSTAPP_BUILD_DIR)
	$(MAKE) -C $(HOSTAPP_BUILD_DIR) -j`nproc` all

# -----------------------------------------------------------------------------
#  EXAMPLES -------------------------------------------------------------------
# -----------------------------------------------------------------------------

EXAMPLE_INPUT_FILE = $(EXAMPLE_BUILD_DIR)/input.bin
EXAMPLE_OUTPUT_FILE = $(EXAMPLE_BUILD_DIR)/output.bin
EXAMPLE_BPF_OBJECT_FILE = $(EXAMPLE_BUILD_DIR)/bpf.o

.PHONY: load-example
load-example: $(EXAMPLE_OUTPUT_FILE) ## Load example specified by EXAMPLE to nvme device specified by NVME_DEVICE

$(EXAMPLE_BUILD_DIR):
	@mkdir -p $@

$(EXAMPLE_INPUT_FILE): $(EXAMPLE_DIR)/model.tflite
$(EXAMPLE_INPUT_FILE): $(EXAMPLE_DIR)/input-vector.bin
$(EXAMPLE_INPUT_FILE): | $(EXAMPLE_BUILD_DIR)
	cat $(EXAMPLE_DIR)/model.tflite $(EXAMPLE_DIR)/input-vector.bin > $(EXAMPLE_INPUT_FILE)

$(EXAMPLE_BPF_OBJECT_FILE): $(EXAMPLE_DIR)/bpf.c
$(EXAMPLE_BPF_OBJECT_FILE): | $(EXAMPLE_BUILD_DIR)
	clang -O2 -target bpf -c $(EXAMPLE_DIR)/bpf.c -o $(EXAMPLE_BPF_OBJECT_FILE)

$(EXAMPLE_OUTPUT_FILE): $(HOSTAPP_OUTPUTS)
$(EXAMPLE_OUTPUT_FILE): $(EXAMPLE_INPUT_FILE)
$(EXAMPLE_OUTPUT_FILE): $(EXAMPLE_BPF_OBJECT_FILE)
	@if [ -z "$(NVME_DEVICE)" ]; then echo "ERROR: Please set NVME_DEVICE variable" && exit 1; fi
	$(HOSTAPP_DIR)/run.sh $(NVME_DEVICE) $(EXAMPLE_BPF_OBJECT_FILE) $(EXAMPLE_INPUT_FILE) $(EXAMPLE_OUTPUT_FILE)

# -----------------------------------------------------------------------------
# Docker ----------------------------------------------------------------------
# -----------------------------------------------------------------------------

REGGEN_REL_DIR = $(shell realpath --relative-to $(ROOT_DIR) $(REGGEN_DIR))
FW_REL_DIR = $(shell realpath --relative-to $(ROOT_DIR) $(FW_ROOT_DIR))
DOCKER_BUILD_DIR = $(BUILD_DIR)/docker
DOCKER_BUILD_REGGEN_REQS_DIR = $(DOCKER_BUILD_DIR)/$(REGGEN_REL_DIR)
DOCKER_BUILD_FW_REQS_DIR = $(DOCKER_BUILD_DIR)/$(FW_REL_DIR)

$(DOCKER_BUILD_REGGEN_REQS_DIR):
	@mkdir -p $@

.PHONY: docker
docker: alkali.dockerfile  ## Build the development docker image
docker: requirements.txt
docker: $(FW_ROOT_DIR)/requirements.txt
docker: $(REGGEN_DIR)/requirements.txt
docker: | $(DOCKER_BUILD_REGGEN_REQS_DIR)
	cp alkali.dockerfile $(DOCKER_BUILD_DIR)/Dockerfile
	cp $(ROOT_DIR)/requirements.txt $(DOCKER_BUILD_DIR)/requirements.txt
	mkdir -p $(DOCKER_BUILD_REGGEN_REQS_DIR)
	cp $(FW_ROOT_DIR)/requirements.txt $(DOCKER_BUILD_FW_REQS_DIR)/requirements.txt
	cp $(REGGEN_DIR)/requirements.txt $(DOCKER_BUILD_REGGEN_REQS_DIR)/requirements.txt
	cd $(DOCKER_BUILD_DIR) && docker build \
		$(DOCKER_BUILD_EXTRA_ARGS) \
		-t $(DOCKER_TAG) .

.PHONY: docker/clean
docker/clean: ## Clean Docker build files
	$(RM) -r $(DOCKER_BUILD_DIR)

# -----------------------------------------------------------------------------
# Enter -----------------------------------------------------------------------
# -----------------------------------------------------------------------------

.PHONY: enter
enter: ## Enter the development docker image
	docker run \
		--rm \
		-v $(PWD):$(PWD) \
		-v /etc/passwd:/etc/passwd \
		-v /etc/group:/etc/group \
		-v /tmp:$(HOME)/.cache \
		-v /tmp:$(HOME)/.sbt \
		-v /tmp:$(HOME)/.Xilinx \
		-e CCACHE_DISABLE=1 \
		-u $(shell id -u):$(shell id -g) \
		-h docker-container \
		-w $(PWD) \
		-it \
		$(DOCKER_RUN_EXTRA_ARGS) \
		$(DOCKER_TAG)

# -----------------------------------------------------------------------------
# Help ------------------------------------------------------------------------
# -----------------------------------------------------------------------------

HELP_COLUMN_SPAN = 30
HELP_FORMAT_STRING = "\033[36m%-$(HELP_COLUMN_SPAN)s\033[0m %s\n"
.PHONY: help
help: ## Show this help message
	@echo Here is the list of available targets:
	@echo ""
	@grep -hE '^[^#[:blank:]]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf $(HELP_FORMAT_STRING), $$1, $$2}'
	@echo ""
	@echo "Additionally, you can use the following environment variables:"
	@echo ""
	@printf $(HELP_FORMAT_STRING) "BOARD" "The board to build the gateware for ('an300' or 'zcu106')"
	@printf $(HELP_FORMAT_STRING) "BAR_SIZE" "bar size with unit (e.g. 16MB)"
	@printf $(HELP_FORMAT_STRING) "EXAMPLE" "name of the example to run (name of the chosen directory in examples/)"
	@printf $(HELP_FORMAT_STRING) "NVME_DEVICE" "nvme device to use"
	@printf $(HELP_FORMAT_STRING) "DOCKER_IMAGE_PREFIX" "registry prefix with '/' at the end"
	@printf $(HELP_FORMAT_STRING) "DOCKER_TAG" "docker tag for building and running images"
	@printf $(HELP_FORMAT_STRING) "DOCKER_RUN_EXTRA_ARGS" "Extra arguments for running docker container"
	@printf $(HELP_FORMAT_STRING) "DOCKER_BUILD_EXTRA_ARGS" "Extra arguments for building docker"

.DEFAULT_GOAL := help
