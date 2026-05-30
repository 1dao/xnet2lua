ROOT ?= ..
CC ?= gcc
BUILD_MODE ?= release
WITH_HTTPS ?= 1
WITH_RPMALLOC ?= 1
WITH_XDEBUG ?= 0
LUA_BACKEND ?= minilua
LUAJIT_DIR ?= 3rd/luajit
LUAJIT_INC ?= $(LUAJIT_DIR)/src
LUAJIT_LIB ?= $(LUAJIT_DIR)/src/libluajit.a
GCOV ?= gcov

BASE_CFLAGS := -Wall -Wextra -I$(ROOT) -MMD -MP

ifeq ($(WITH_RPMALLOC),1)
	BASE_CFLAGS += -DENABLE_OVERRIDE=0 -DXMACRO_USE_RPMALLOC=1
else
	BASE_CFLAGS += -DXMACRO_USE_RPMALLOC=0
endif
ifeq ($(BUILD_MODE),debug)
	CFLAGS := $(BASE_CFLAGS) -O0 -g -DDEBUG
else ifeq ($(BUILD_MODE),release)
	CFLAGS := $(BASE_CFLAGS) -O2 -DNDEBUG
else
	$(error Unsupported BUILD_MODE '$(BUILD_MODE)'; expected 'debug' or 'release')
endif

EXE_EXT :=
SYS_LDFLAGS :=
RM := rm -rf
MKDIR := mkdir -p
MV := mv -f

ifeq ($(OS),Windows_NT)
	EXE_EXT := .exe
	SYS_LDFLAGS += -lws2_32 -ladvapi32
	RM := /usr/bin/rm -rf
	MV := /usr/bin/mv -f
else
	SYS_LDFLAGS += -lpthread -lm
endif

ifeq ($(WITH_HTTPS),1)
ifeq ($(OS),Windows_NT)
	SYS_LDFLAGS += -lbcrypt
endif
endif

BIN_DIR := $(ROOT)/bin
COVERAGE_DIR := $(ROOT)/coverage
XNET_RUNNER := bin/xnet$(EXE_EXT)

ifeq ($(WITH_RPMALLOC),1)
	RPMALLOC_SRC := $(ROOT)/3rd/rpmalloc/rpmalloc.c
else
	RPMALLOC_SRC :=
endif

XTHREAD_TEST_SRCS := $(ROOT)/demo/xthread_test.c $(ROOT)/xthread.c $(ROOT)/xpoll.c $(ROOT)/xsock.c $(ROOT)/xdaemon.c $(ROOT)/xlog.c $(RPMALLOC_SRC)
XTHREAD_TEST_BUILD := $(BIN_DIR)/xthread_test_build$(EXE_EXT)
XTHREAD_TEST_TARGET := $(BIN_DIR)/xthread_test$(EXE_EXT)
XTHREAD_TEST_RUNNER := bin/xthread_test$(EXE_EXT)

C_UNIT_LOCAL_SRCS := c/test_core.c
C_UNIT_ROOT_SRCS := xargs.c xtimer.c xpoll.c xlog.c
C_UNIT_SRCS := $(C_UNIT_LOCAL_SRCS) $(addprefix $(ROOT)/,$(C_UNIT_ROOT_SRCS))
C_UNIT_BUILD := $(BIN_DIR)/test_core_build$(EXE_EXT)
C_UNIT_TARGET := $(BIN_DIR)/test_core$(EXE_EXT)
C_UNIT_RUNNER := bin/test_core$(EXE_EXT)
C_UNIT_CFLAGS := -Wall -Wextra -I$(ROOT) -MMD -MP -DXMACRO_USE_RPMALLOC=0

C_UNIT_COVERAGE_OBJS := \
	$(addprefix $(COVERAGE_DIR)/tests/,$(C_UNIT_LOCAL_SRCS:.c=.o)) \
	$(addprefix $(COVERAGE_DIR)/,$(C_UNIT_ROOT_SRCS:.c=.o))
C_UNIT_COVERAGE_TARGET := $(BIN_DIR)/test_core_coverage$(EXE_EXT)
C_UNIT_COVERAGE_RUNNER := bin/test_core_coverage$(EXE_EXT)
C_UNIT_COVERAGE_CFLAGS := $(C_UNIT_CFLAGS) -O0 -g --coverage
C_UNIT_COVERAGE_LDFLAGS := $(SYS_LDFLAGS) --coverage

LUA_UNIT_SCRIPTS := \
	tests/lua/http_codec_spec.lua \
	tests/lua/zone_spec.lua \
	tests/lua/zone_host_spec.lua \
	tests/lua/combat_spec.lua \
	tests/lua/peer_codec_spec.lua \
	tests/lua/peer_mesh_spec.lua \
	tests/lua/border_aoi_spec.lua \
	tests/lua/combat_flow_spec.lua \
	tests/lua/cluster_spec.lua \
	tests/lua/gameload_spec.lua \
	tests/lua/metrics_spec.lua \
	tests/lua/chat_spec.lua \
	tests/lua/chatfilter_spec.lua \
	tests/lua/mailbox_spec.lua \
	tests/lua/fault_drill_spec.lua \
	tests/lua/player_route_spec.lua

LUA_TEST_CORE_SCRIPTS := \
	demo/xutils_main.lua \
	demo/xtimer_main.lua \
	demo/xtimerx_test.lua \
	demo/xlua_main.lua \
	demo/xnet_main.lua \
	demo/xrouter_test.lua \
	demo/xhttp_router_test.lua \
	demo/xhttp_main.lua

LUA_TEST_EXTERNAL_SCRIPTS := \
	demo/xhttps_main.lua \
	demo/xredis_main.lua \
	demo/xmysql_main.lua \
	demo/xnats_main.lua

ROOT_BUILD_ARGS := \
	CC="$(CC)" \
	BUILD_MODE="$(BUILD_MODE)" \
	WITH_HTTPS="$(WITH_HTTPS)" \
	WITH_RPMALLOC="$(WITH_RPMALLOC)" \
	WITH_XDEBUG="$(WITH_XDEBUG)" \
	LUA_BACKEND="$(LUA_BACKEND)" \
	LUAJIT_DIR="$(LUAJIT_DIR)" \
	LUAJIT_INC="$(LUAJIT_INC)" \
	LUAJIT_LIB="$(LUAJIT_LIB)"

SELF_ARGS := \
	ROOT="$(ROOT)" \
	CC="$(CC)" \
	WITH_XDEBUG="$(WITH_XDEBUG)" \
	LUA_BACKEND="$(LUA_BACKEND)" \
	LUAJIT_DIR="$(LUAJIT_DIR)" \
	LUAJIT_INC="$(LUAJIT_INC)" \
	LUAJIT_LIB="$(LUAJIT_LIB)"

.PHONY: matrix ci-fast ci-feature coverage coverage-c test unit unit-c unit-lua test-c xthread_test test-lua-core test-lua-external test-lua-all run-lua xnet clean

matrix: ci-fast ci-feature

ci-fast:
	$(MAKE) -B test $(SELF_ARGS) BUILD_MODE=debug WITH_HTTPS=0 WITH_RPMALLOC=0

ci-feature:
	$(MAKE) -B unit $(SELF_ARGS) BUILD_MODE=release WITH_HTTPS=1 WITH_RPMALLOC=1

coverage: coverage-c

coverage-c: $(C_UNIT_COVERAGE_TARGET)
	@set -e; \
	cd $(ROOT); \
	$(C_UNIT_COVERAGE_RUNNER); \
	$(GCOV) -o coverage/tests/c tests/c/test_core.c; \
	for src in $(C_UNIT_ROOT_SRCS); do \
		$(GCOV) -o coverage $$src; \
	done

test: unit test-c test-lua-core

unit: unit-c unit-lua

unit-c: $(C_UNIT_TARGET)
	cd $(ROOT) && $(C_UNIT_RUNNER)

unit-lua: xnet
	@set -e; \
	cd $(ROOT); \
	for script in $(LUA_UNIT_SCRIPTS); do \
		echo "==> $$script"; \
		$(XNET_RUNNER) $$script; \
	done

test-c: xthread_test
	cd $(ROOT) && $(XTHREAD_TEST_RUNNER)

xthread_test: $(XTHREAD_TEST_TARGET)

test-lua-core: xnet
	@set -e; \
	cd $(ROOT); \
	for script in $(LUA_TEST_CORE_SCRIPTS); do \
		echo "==> $$script"; \
		$(XNET_RUNNER) $$script; \
	done

test-lua-external: xnet
	@set -e; \
	cd $(ROOT); \
	for script in $(LUA_TEST_EXTERNAL_SCRIPTS); do \
		echo "==> $$script"; \
		$(XNET_RUNNER) $$script; \
	done

test-lua-all: test-lua-core test-lua-external

run-lua: xnet
	@if [ -z "$(SCRIPT)" ]; then \
		echo "Usage: make -C tests run-lua SCRIPT=demo/xutils_main.lua"; \
		exit 1; \
	fi
	cd $(ROOT) && $(XNET_RUNNER) $(SCRIPT)

xnet:
	$(MAKE) -C $(ROOT) xnet $(ROOT_BUILD_ARGS)

$(XTHREAD_TEST_TARGET): $(XTHREAD_TEST_SRCS) | $(BIN_DIR)
	$(RM) $(XTHREAD_TEST_BUILD)
	$(CC) $(CFLAGS) -o $(XTHREAD_TEST_BUILD) $(XTHREAD_TEST_SRCS) $(SYS_LDFLAGS)
	$(MV) $(XTHREAD_TEST_BUILD) $(XTHREAD_TEST_TARGET)

$(C_UNIT_TARGET): $(C_UNIT_SRCS) | $(BIN_DIR)
	$(RM) $(C_UNIT_BUILD)
	$(CC) $(C_UNIT_CFLAGS) -o $(C_UNIT_BUILD) $(C_UNIT_SRCS) $(SYS_LDFLAGS)
	$(MV) $(C_UNIT_BUILD) $(C_UNIT_TARGET)

$(C_UNIT_COVERAGE_TARGET): $(C_UNIT_COVERAGE_OBJS) | $(BIN_DIR)
	$(RM) $(C_UNIT_COVERAGE_TARGET)
	$(CC) -o $(C_UNIT_COVERAGE_TARGET) $(C_UNIT_COVERAGE_OBJS) $(C_UNIT_COVERAGE_LDFLAGS)

$(COVERAGE_DIR)/tests/%.o: %.c
	$(MKDIR) $(dir $@)
	$(CC) $(C_UNIT_COVERAGE_CFLAGS) -c $< -o $@

$(COVERAGE_DIR)/%.o: $(ROOT)/%.c
	$(MKDIR) $(dir $@)
	$(CC) $(C_UNIT_COVERAGE_CFLAGS) -c $< -o $@

$(BIN_DIR):
	$(MKDIR) $(BIN_DIR)

clean:
	$(RM) $(COVERAGE_DIR) $(ROOT)/*.gcov $(XTHREAD_TEST_BUILD) $(XTHREAD_TEST_TARGET) $(C_UNIT_BUILD) $(C_UNIT_TARGET) $(C_UNIT_COVERAGE_TARGET) c/.xargs_test.cfg
