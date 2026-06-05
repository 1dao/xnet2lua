LIB_NAME := xnet
CC ?= gcc
AR ?= ar
ARFLAGS ?= rcs
.DEFAULT_GOAL := all

WITH_IO_URING ?= 0
WITH_HTTP ?= 1
WITH_HTTPS ?= 1
WITH_XDEBUG ?= 0
# WITH_RPMALLOC=1 (default): route allocs through rpmalloc via xmacro.h,
#   link 3rd/rpmalloc/rpmalloc.c.
# WITH_RPMALLOC=0: pass through to libc; useful for ASan/Valgrind/A-B perf.
#   xmacro.h stubs out the rpmalloc_* lifecycle API as no-ops so callers
#   compile unchanged.
WITH_RPMALLOC ?= 1
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
QJS_DIR ?= 3rd/quickjs
BUILD_MODE ?= release

BASE_CFLAGS := -Wall -Wextra -I. -MMD -MP
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
    # ENABLE_OVERRIDE=0 stops rpmalloc.c from pulling in malloc.c which would
    # hijack libc's malloc/calloc/free symbol-wise. We route via xmacro.h
    # instead. Also required to avoid an infinite recursion under MinGW emutls
    # (calls calloc internally to materialise _Thread_local; would otherwise
    # re-enter rpcalloc).
    BASE_CFLAGS  += -DENABLE_OVERRIDE=0 -DXMACRO_USE_RPMALLOC=1
else
    BASE_CFLAGS  += -DXMACRO_USE_RPMALLOC=0
endif
ifeq ($(BUILD_MODE),debug)
	CFLAGS := $(BASE_CFLAGS) -O0 -g -DDEBUG $(SANITIZE_CFLAGS)
else ifeq ($(BUILD_MODE),release)
	CFLAGS := $(BASE_CFLAGS) -O2 -DNDEBUG $(SANITIZE_CFLAGS)
else
	$(error Unsupported BUILD_MODE '$(BUILD_MODE)'; expected 'debug' or 'release')
endif

OBJ_DIR := obj
BIN_DIR := bin

ifeq ($(SANITIZE),asan)
    OBJ_DIR := obj/asan
    TARGET_LIB := $(OBJ_DIR)/lib$(LIB_NAME).a
else
    TARGET_LIB := lib$(LIB_NAME).a
endif
CORE_SRCS := xargs.c xpoll.c xsock.c xchannel.c xthread.c xtimer.c xdaemon.c xlog.c
CORE_OBJS := $(addprefix $(OBJ_DIR)/,$(CORE_SRCS:.c=.o))
CORE_DEPS := $(CORE_OBJS:.o=.d)

EXE_EXT :=
SYS_LDFLAGS :=
QJS_EXTRA_LDFLAGS :=
RM := rm -rf
MKDIR := mkdir -p
MV := mv -f

ifeq ($(OS),Windows_NT)
	EXE_EXT := .exe
	SYS_LDFLAGS += -lws2_32 -ladvapi32 -lbcrypt
	RM := /usr/bin/rm -rf
	MV := /usr/bin/mv -f
else
	SYS_LDFLAGS += -lpthread -lm
	QJS_EXTRA_LDFLAGS += -ldl
endif

XNET_DEFS := -DXNET_WITH_HTTP=$(WITH_HTTP) -DXNET_WITH_HTTPS=$(WITH_HTTPS)
XNET_CFLAGS := -I3rd/libdeflate
QJS_CFLAGS := -I$(QJS_DIR) -D_GNU_SOURCE -DQUICKJS_NG_BUILD -Wno-unused-parameter -Wno-sign-compare -Wno-implicit-fallthrough
ifeq ($(OS),Windows_NT)
	QJS_CFLAGS += -DWIN32_LEAN_AND_MEAN -D_WIN32_WINNT=0x0601
endif
XNET_HTTPS_SRC :=

# Pick libdeflate's per-arch cpu_features.c based on the host machine.
# crc32.c et al. resolve libdeflate_{arm,x86}_cpu_features at link time,
# so the wrong file leaves undefined symbols (seen on macOS arm64 CI).
# The xnet target compiles sources straight into the binary (no flat
# $(OBJ_DIR)/%.o rule), so x86/arm basename collision doesn't apply here.
ifeq ($(OS),Windows_NT)
    XNET_HOST_ARCH := x86_64
else
    XNET_HOST_ARCH := $(shell uname -m)
endif
ifneq (,$(filter $(XNET_HOST_ARCH),arm64 aarch64))
    XNET_CPU_FEATURES_SRC := 3rd/libdeflate/lib/arm/cpu_features.c
else
    XNET_CPU_FEATURES_SRC := 3rd/libdeflate/lib/x86/cpu_features.c
endif
XNET_DEFLATE_SRC := $(wildcard 3rd/libdeflate/lib/*.c) $(XNET_CPU_FEATURES_SRC)
XNET_UTIL_SRC := 3rd/yyjson.c xlua/lua_xutils.c xframe_aead.c $(XNET_DEFLATE_SRC)
XNET_LUA_SRC := xlua/lua_xthread.c xlua/lua_xnet.c xlua/lua_xnet_tls.c xlua/lua_cmsgpack.c xlua/lua_xtimer.c xlua/lua_xcompress.c
XNET_DEBUG_SRC :=
XNET_LUA_LIB :=
XNET_EXTRA_LDFLAGS :=
XNET_BUILD := $(BIN_DIR)/xnet$(PROGRAM_SUFFIX)_build$(EXE_EXT)
XNET_TARGET := $(BIN_DIR)/xnet$(PROGRAM_SUFFIX)$(EXE_EXT)
XJS_BUILD := $(BIN_DIR)/xjs_build$(EXE_EXT)
XJS_TARGET := $(BIN_DIR)/xjs$(EXE_EXT)
QJS_SRC := $(QJS_DIR)/dtoa.c $(QJS_DIR)/libregexp.c $(QJS_DIR)/libunicode.c $(QJS_DIR)/quickjs.c $(QJS_DIR)/quickjs-libc.c
XJS_SRC := xjs/xnet_main.c xjs/xjs_common.c xjs/xjs_runtime.c xjs/js_xutils.c xjs/js_xtimer.c xjs/js_xthread.c xjs/js_xnet.c

# rpmalloc is consumed by everything that uses libxnet.a or compiles xthread.c
# directly. libxnet.a itself does NOT contain rpmalloc symbols, so xnet adds
# it here and tests/Makefile adds it for xthread_test.
# Empty when WITH_RPMALLOC=0; xmacro.h then stubs the lifecycle API.
ifeq ($(WITH_RPMALLOC),1)
    RPMALLOC_SRC := 3rd/rpmalloc/rpmalloc.c
else
    RPMALLOC_SRC :=
endif

ifeq ($(LUA_BACKEND),minilua)
	XNET_DEFS += -DLUA_EMBEDDED
else ifeq ($(LUA_BACKEND),luajit)
	XNET_DEFS += -DXLUA_USE_LUAJIT=1
	XNET_CFLAGS += -I$(LUAJIT_INC)
	XNET_LUA_LIB := $(LUAJIT_LIB)
ifneq ($(OS),Windows_NT)
	XNET_EXTRA_LDFLAGS += -ldl
endif
else
	$(error Unsupported LUA_BACKEND '$(LUA_BACKEND)'; expected 'minilua' or 'luajit')
endif

ifeq ($(WITH_XDEBUG),1)
	XNET_DEFS += -DXNET_WITH_XDEBUG=1
	XNET_DEBUG_SRC := xlua/lua_xdebug.c
else
	XNET_DEFS += -DXNET_WITH_XDEBUG=0
endif

ifeq ($(WITH_IO_URING),1)
ifneq ($(OS),Windows_NT)
	CFLAGS += -DXPOLL_USE_IO_URING -DXCHANNEL_USE_IO_URING
	SYS_LDFLAGS += -luring
endif
endif

ifeq ($(WITH_HTTPS),1)
	XNET_CFLAGS += -I3rd/mbedtls3/include
	XNET_HTTPS_SRC := $(wildcard 3rd/mbedtls3/library/*.c)
endif

XDEBUG_DAP_SRCS := tools/xdebug_dap.c xsock.c xpoll.c xlog.c
XDEBUG_DAP_TARGET := tools/xdebug_dap$(PROGRAM_SUFFIX)$(EXE_EXT)

TEST_TARGETS := matrix ci-fast ci-feature coverage coverage-c test unit unit-c unit-lua test-c xthread_test test-lua-core test-lua-external test-lua-all
TEST_MAKE := $(MAKE) -C tests ROOT=.. CC="$(CC)" BUILD_MODE="$(BUILD_MODE)" SANITIZE="$(SANITIZE)" WITH_HTTPS="$(WITH_HTTPS)" WITH_RPMALLOC="$(WITH_RPMALLOC)" WITH_XDEBUG="$(WITH_XDEBUG)" WITH_IO_URING="$(WITH_IO_URING)" LUA_BACKEND="$(LUA_BACKEND)" LUAJIT_DIR="$(LUAJIT_DIR)" LUAJIT_INC="$(LUAJIT_INC)" LUAJIT_LIB="$(LUAJIT_LIB)"
ASAN_BUILD_ARGS := BUILD_MODE=debug SANITIZE=asan WITH_RPMALLOC=0

xdebug_dap: $(XDEBUG_DAP_TARGET)

$(XDEBUG_DAP_TARGET): $(XDEBUG_DAP_SRCS)
	$(RM) $(XDEBUG_DAP_TARGET)
	$(CC) -Wall -Wextra -I. -MMD -MP -DXMACRO_USE_RPMALLOC=0 $(SANITIZE_CFLAGS) -o $@ $(XDEBUG_DAP_SRCS) $(SANITIZE_LDFLAGS) $(SYS_LDFLAGS)

.PHONY: all xnet xjs xjs-asan xdebug_dap asan asan-test asan-unit asan-run-lua clean $(TEST_TARGETS) run-lua run-js

all: $(TARGET_LIB) $(XNET_TARGET) $(XJS_TARGET) $(XDEBUG_DAP_TARGET)

xnet: $(XNET_TARGET)

xjs: $(XJS_TARGET)

xjs-asan:
	$(MAKE) -B xjs CC="/c/software/msys64/clang64/bin/clang -fsanitize=address -fno-omit-frame-pointer -g" BUILD_MODE=debug WITH_RPMALLOC=0

asan:
	$(MAKE) -B all $(ASAN_BUILD_ARGS)

asan-test:
	ASAN_OPTIONS="$(ASAN_OPTIONS)" $(MAKE) -B test $(ASAN_BUILD_ARGS)

asan-unit:
	ASAN_OPTIONS="$(ASAN_OPTIONS)" $(MAKE) -B unit $(ASAN_BUILD_ARGS)

asan-run-lua:
	@if [ -z "$(SCRIPT)" ]; then \
		echo "Usage: make asan-run-lua SCRIPT=demo/xutils_main.lua"; \
		exit 1; \
	fi
	ASAN_OPTIONS="$(ASAN_OPTIONS)" $(MAKE) -B run-lua $(ASAN_BUILD_ARGS) SCRIPT="$(SCRIPT)"

$(TARGET_LIB): $(CORE_OBJS)
	$(AR) $(ARFLAGS) $@ $(CORE_OBJS)

$(OBJ_DIR)/%.o: %.c | $(OBJ_DIR)
	$(CC) $(CFLAGS) -c $< -o $@

$(XNET_TARGET): xlua/xnet_main.c $(XNET_LUA_SRC) $(XNET_DEBUG_SRC) $(XNET_UTIL_SRC) $(RPMALLOC_SRC) $(TARGET_LIB) $(XNET_HTTPS_SRC) $(XNET_LUA_LIB) | $(BIN_DIR)
	$(RM) $(XNET_BUILD)
	$(CC) $(CFLAGS) $(XNET_CFLAGS) $(XNET_DEFS) -o $(XNET_BUILD) xlua/xnet_main.c $(XNET_LUA_SRC) $(XNET_DEBUG_SRC) $(XNET_UTIL_SRC) $(XNET_HTTPS_SRC) $(RPMALLOC_SRC) $(TARGET_LIB) $(XNET_LUA_LIB) $(SANITIZE_LDFLAGS) $(SYS_LDFLAGS) $(XNET_EXTRA_LDFLAGS)
	$(MV) $(XNET_BUILD) $(XNET_TARGET)

$(XJS_TARGET): $(XJS_SRC) $(QJS_SRC) $(RPMALLOC_SRC) $(TARGET_LIB) | $(BIN_DIR)
	$(RM) $(XJS_BUILD)
	$(CC) $(CFLAGS) $(QJS_CFLAGS) $(XNET_DEFS) -o $(XJS_BUILD) $(XJS_SRC) $(QJS_SRC) $(RPMALLOC_SRC) $(TARGET_LIB) $(SANITIZE_LDFLAGS) $(SYS_LDFLAGS) $(QJS_EXTRA_LDFLAGS)
	$(MV) $(XJS_BUILD) $(XJS_TARGET)

$(OBJ_DIR):
	$(MKDIR) $(OBJ_DIR)

$(BIN_DIR):
	$(MKDIR) $(BIN_DIR)

$(TEST_TARGETS):
	$(TEST_MAKE) $@

run-lua: $(XNET_TARGET)
	@if [ -z "$(SCRIPT)" ]; then \
		echo "Usage: make run-lua SCRIPT=demo/xutils_main.lua"; \
		exit 1; \
	fi
	$(XNET_TARGET) $(SCRIPT)

run-js: $(XJS_TARGET)
	@if [ -z "$(SCRIPT)" ]; then \
		echo "Usage: make run-js SCRIPT=demo/xjs_main.mjs"; \
		exit 1; \
	fi
	$(XJS_TARGET) $(SCRIPT)

clean:
	$(RM) obj lib$(LIB_NAME).a $(BIN_DIR)/xnet$(EXE_EXT) $(BIN_DIR)/xnet_asan$(EXE_EXT) $(BIN_DIR)/xnet_build$(EXE_EXT) $(BIN_DIR)/xnet_asan_build$(EXE_EXT) $(BIN_DIR)/xjs$(EXE_EXT) $(BIN_DIR)/xjs_build$(EXE_EXT) tools/xdebug_dap$(EXE_EXT) tools/xdebug_dap_asan$(EXE_EXT) tools/xdebug_dap.d tools/xdebug_dap_asan.d
	$(TEST_MAKE) clean

-include $(CORE_DEPS)
