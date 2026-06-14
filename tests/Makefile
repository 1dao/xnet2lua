ROOT ?= ..
CC ?= gcc
BUILD_MODE ?= release
WITH_HTTPS ?= 1
WITH_RPMALLOC ?= 1
WITH_XDEBUG ?= 0
WITH_IO_URING ?= 0
SANITIZE ?= none
ifeq ($(OS),Windows_NT)
ASAN_OPTIONS ?= halt_on_error=1:abort_on_error=1:strict_string_checks=1
else
ASAN_OPTIONS ?= detect_leaks=1:halt_on_error=1:abort_on_error=1:strict_string_checks=1
endif
LUA_BACKEND ?= minilua
LUAJIT_DIR ?= 3rd/luajit
LUAJIT_INC ?= $(LUAJIT_DIR)/src
LUAJIT_LIB ?= $(LUAJIT_DIR)/src/libluajit.a
GCOV ?= gcov

BASE_CFLAGS := -Wall -Wextra -I$(ROOT) -MMD -MP
SANITIZE_CFLAGS :=
SANITIZE_LDFLAGS :=
PROGRAM_SUFFIX :=

ifeq ($(SANITIZE),asan)
	override WITH_RPMALLOC := 0
	SANITIZE_CFLAGS := -fsanitize=address -fno-omit-frame-pointer -fno-common
	SANITIZE_LDFLAGS := -fsanitize=address
	PROGRAM_SUFFIX := _asan
	export ASAN_OPTIONS
else ifneq ($(SANITIZE),none)
	$(error Unsupported SANITIZE '$(SANITIZE)'; expected 'none' or 'asan')
endif

ifeq ($(WITH_RPMALLOC),1)
	BASE_CFLAGS += -DENABLE_OVERRIDE=0 -DXMACRO_USE_RPMALLOC=1
else
	BASE_CFLAGS += -DXMACRO_USE_RPMALLOC=0
endif
ifeq ($(WITH_IO_URING),1)
ifneq ($(OS),Windows_NT)
	BASE_CFLAGS += -DXPOLL_USE_IO_URING -DXCHANNEL_USE_IO_URING
endif
endif
ifeq ($(BUILD_MODE),debug)
	CFLAGS := $(BASE_CFLAGS) -O0 -g -DDEBUG $(SANITIZE_CFLAGS)
else ifeq ($(BUILD_MODE),release)
	CFLAGS := $(BASE_CFLAGS) -O2 -DNDEBUG $(SANITIZE_CFLAGS)
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

ifeq ($(WITH_IO_URING),1)
ifneq ($(OS),Windows_NT)
	SYS_LDFLAGS += -luring
endif
endif

ifeq ($(WITH_HTTPS),1)
ifeq ($(OS),Windows_NT)
	SYS_LDFLAGS += -lbcrypt
endif
endif

BIN_DIR := $(ROOT)/bin
COVERAGE_DIR := $(ROOT)/coverage
XNET_RUNNER := bin/xnet$(PROGRAM_SUFFIX)$(EXE_EXT)

ifeq ($(WITH_RPMALLOC),1)
	RPMALLOC_SRC := $(ROOT)/3rd/rpmalloc/rpmalloc.c
else
	RPMALLOC_SRC :=
endif

XTHREAD_TEST_SRCS := $(ROOT)/demo/xthread_test.c $(ROOT)/xthread.c $(ROOT)/xpoll.c $(ROOT)/xsock.c $(ROOT)/xdaemon.c $(ROOT)/xlog.c $(RPMALLOC_SRC)
XTHREAD_TEST_BUILD := $(BIN_DIR)/xthread_test$(PROGRAM_SUFFIX)_build$(EXE_EXT)
XTHREAD_TEST_TARGET := $(BIN_DIR)/xthread_test$(PROGRAM_SUFFIX)$(EXE_EXT)
XTHREAD_TEST_RUNNER := bin/xthread_test$(PROGRAM_SUFFIX)$(EXE_EXT)

C_UNIT_LOCAL_SRCS := c/test_core.c
C_UNIT_ROOT_SRCS := xargs.c xtimer.c xpoll.c xlog.c
C_UNIT_SRCS := $(C_UNIT_LOCAL_SRCS) $(addprefix $(ROOT)/,$(C_UNIT_ROOT_SRCS))
C_UNIT_BUILD := $(BIN_DIR)/test_core$(PROGRAM_SUFFIX)_build$(EXE_EXT)
C_UNIT_TARGET := $(BIN_DIR)/test_core$(PROGRAM_SUFFIX)$(EXE_EXT)
C_UNIT_RUNNER := bin/test_core$(PROGRAM_SUFFIX)$(EXE_EXT)
C_UNIT_CFLAGS := -Wall -Wextra -I$(ROOT) -MMD -MP -DXMACRO_USE_RPMALLOC=0 $(SANITIZE_CFLAGS)
ifeq ($(WITH_IO_URING),1)
ifneq ($(OS),Windows_NT)
	C_UNIT_CFLAGS += -DXPOLL_USE_IO_URING
endif
endif

C_UNIT_COVERAGE_OBJS := \
	$(addprefix $(COVERAGE_DIR)/tests/,$(C_UNIT_LOCAL_SRCS:.c=.o)) \
	$(addprefix $(COVERAGE_DIR)/,$(C_UNIT_ROOT_SRCS:.c=.o))
C_UNIT_COVERAGE_TARGET := $(BIN_DIR)/test_core_coverage$(EXE_EXT)
C_UNIT_COVERAGE_RUNNER := bin/test_core_coverage$(EXE_EXT)
C_UNIT_COVERAGE_CFLAGS := $(C_UNIT_CFLAGS) -O0 -g --coverage
C_UNIT_COVERAGE_LDFLAGS := $(SYS_LDFLAGS) --coverage

LUA_UNIT_SCRIPTS := \
	tests/lua/http_codec_spec.lua \
	tests/lua/http_client_spec.lua \
	tests/lua/websocket_spec.lua \
	tests/lua/xutils_crypto_spec.lua \
	tests/lua/xagent_llm_spec.lua \
	tests/lua/xagent_tools_spec.lua \
	tests/lua/xagent_session_spec.lua \
	tests/lua/xagent_context_spec.lua \
	tests/lua/xagent_skills_spec.lua \
	tests/lua/xagent_mcp_spec.lua

LUA_TEST_CORE_SCRIPTS := \
	demo/xutils_main.lua \
	demo/xtimer_main.lua \
	demo/xtimerx_test.lua \
	demo/xlua_main.lua \
	demo/xnet_main.lua \
	demo/xrouter_test.lua \
	demo/xhttp_router_test.lua \
	demo/xhttp_main.lua \
	demo/xhttp_ws_main.lua \
	demo/xhttp_client_main.lua

LUA_TEST_EXTERNAL_SCRIPTS := \
	demo/xhttps_main.lua \
	demo/xhttp_wss_main.lua \
	demo/xredis_main.lua \
	demo/xmysql_main.lua \
	demo/xnats_main.lua

ROOT_BUILD_ARGS := \
	CC="$(CC)" \
	BUILD_MODE="$(BUILD_MODE)" \
	SANITIZE="$(SANITIZE)" \
	WITH_HTTPS="$(WITH_HTTPS)" \
	WITH_RPMALLOC="$(WITH_RPMALLOC)" \
	WITH_XDEBUG="$(WITH_XDEBUG)" \
	WITH_IO_URING="$(WITH_IO_URING)" \
	LUA_BACKEND="$(LUA_BACKEND)" \
	LUAJIT_DIR="$(LUAJIT_DIR)" \
	LUAJIT_INC="$(LUAJIT_INC)" \
	LUAJIT_LIB="$(LUAJIT_LIB)"

SELF_ARGS := \
	ROOT="$(ROOT)" \
	CC="$(CC)" \
	SANITIZE="$(SANITIZE)" \
	WITH_XDEBUG="$(WITH_XDEBUG)" \
	WITH_IO_URING="$(WITH_IO_URING)" \
	LUA_BACKEND="$(LUA_BACKEND)" \
	LUAJIT_DIR="$(LUAJIT_DIR)" \
	LUAJIT_INC="$(LUAJIT_INC)" \
	LUAJIT_LIB="$(LUAJIT_LIB)"

ASAN_BUILD_ARGS := BUILD_MODE=debug SANITIZE=asan WITH_RPMALLOC=0

.PHONY: matrix ci-fast ci-feature coverage coverage-c test unit unit-c unit-lua test-c xthread_test test-lua-core test-lua-external test-lua-all asan-test asan-unit asan-run-lua run-lua xnet clean

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
	@$(RM) $(COVERAGE_DIR)

test: unit test-c test-lua-core

unit: unit-c unit-lua

asan-test:
	ASAN_OPTIONS="$(ASAN_OPTIONS)" $(MAKE) -B test $(SELF_ARGS) $(ASAN_BUILD_ARGS)

asan-unit:
	ASAN_OPTIONS="$(ASAN_OPTIONS)" $(MAKE) -B unit $(SELF_ARGS) $(ASAN_BUILD_ARGS)

asan-run-lua:
	@if [ -z "$(SCRIPT)" ]; then \
		echo "Usage: make -C tests asan-run-lua SCRIPT=demo/xutils_main.lua"; \
		exit 1; \
	fi
	ASAN_OPTIONS="$(ASAN_OPTIONS)" $(MAKE) -B run-lua $(SELF_ARGS) $(ASAN_BUILD_ARGS) SCRIPT="$(SCRIPT)"

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
	$(CC) $(CFLAGS) -o $(XTHREAD_TEST_BUILD) $(XTHREAD_TEST_SRCS) $(SANITIZE_LDFLAGS) $(SYS_LDFLAGS)
	$(MV) $(XTHREAD_TEST_BUILD) $(XTHREAD_TEST_TARGET)
	@$(RM) $(XTHREAD_TEST_BUILD:$(EXE_EXT)=.d)

$(C_UNIT_TARGET): $(C_UNIT_SRCS) | $(BIN_DIR)
	$(RM) $(C_UNIT_BUILD)
	$(CC) $(C_UNIT_CFLAGS) -o $(C_UNIT_BUILD) $(C_UNIT_SRCS) $(SANITIZE_LDFLAGS) $(SYS_LDFLAGS)
	$(MV) $(C_UNIT_BUILD) $(C_UNIT_TARGET)
	@$(RM) $(C_UNIT_BUILD:$(EXE_EXT)=.d)

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
	$(RM) $(COVERAGE_DIR) $(ROOT)/*.gcov $(BIN_DIR)/xthread_test$(EXE_EXT) $(BIN_DIR)/xthread_test_asan$(EXE_EXT) $(BIN_DIR)/xthread_test_build$(EXE_EXT) $(BIN_DIR)/xthread_test_asan_build$(EXE_EXT) $(BIN_DIR)/test_core$(EXE_EXT) $(BIN_DIR)/test_core_asan$(EXE_EXT) $(BIN_DIR)/test_core_build$(EXE_EXT) $(BIN_DIR)/test_core_asan_build$(EXE_EXT) $(C_UNIT_COVERAGE_TARGET) c/.xargs_test.cfg
