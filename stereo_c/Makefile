TARGET  := stereo_disparity
SRCDIR  := src
INCDIR  := include
BUILD   := build

NEON    ?= 1
BRL4_INCLUDE ?=

CC      ?= gcc
# Old DE1-SoC images use GCC 4.x (no -std=gnu11). Override with CSTD=gnu11 if you have a newer toolchain.
CSTD    ?= gnu99

# Include dirs are resolved from *this* Makefile (not the shell cwd) so a vendored
# `include/address_map_arm_brl4.h` and parent-dir copies both work. Parent + grandparent
# cover: stereo-vision/ and (if nested) stereo-vision/stereo_c/stereo_c → repo root.
MKFILE_DIR         := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
STEREO_C_PARENT    := $(abspath $(MKFILE_DIR)..)
STEREO_C_G2        := $(abspath $(MKFILE_DIR)../..)
BASE_CFLAGS        := -O2 -Wall -Wextra -Wshadow -std=$(CSTD) \
	-I$(MKFILE_DIR)$(INCDIR) -I$(STEREO_C_PARENT) -I$(STEREO_C_G2)

ifneq ($(strip $(BRL4_INCLUDE)),)
  BASE_CFLAGS += -I$(BRL4_INCLUDE)
endif

ifeq ($(NEON),1)
  BASE_CFLAGS += -mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard -DSTEREO_HAVE_NEON=1
else
  BASE_CFLAGS += -DSTEREO_HAVE_NEON=0
endif

CFLAGS  ?=
CFLAGS  := $(BASE_CFLAGS) $(CFLAGS)
LDFLAGS ?=
LIBS    ?=

SRCS := $(wildcard $(SRCDIR)/*.c)
OBJS := $(patsubst $(SRCDIR)/%.c,$(BUILD)/%.o,$(SRCS))
DEPS := $(OBJS:.o=.d)

.PHONY: all clean

all: $(BUILD)/$(TARGET)

$(BUILD)/$(TARGET): $(OBJS)
	$(CC) $^ -o $@ $(LDFLAGS) $(LIBS)

$(BUILD)/%.o: $(SRCDIR)/%.c | $(BUILD)
	$(CC) $(CFLAGS) -MMD -MP -c $< -o $@

$(BUILD):
	mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD)

-include $(DEPS)
