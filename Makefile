LIB_NAME := xsock
CC ?= gcc
AR ?= ar
ARFLAGS ?= rcs

WITH_IO_URING ?= 0
WITH_HTTP ?= 1
WITH_HTTPS ?= 1
# WITH_RPMALLOC=1 (default): route allocs through rpmalloc via xmacro.h,
#   link 3rd/rpmalloc/rpmalloc.c.
# WITH_RPMALLOC=0: pass through to libc; useful for ASan/Valgrind/A-B perf.
#   xmacro.h stubs out the rpmalloc_* lifecycle API as no-ops so callers
#   compile unchanged.
WITH_RPMALLOC ?= 1
LUA_BACKEND ?= minilua
LUAJIT_DIR ?= 3rd/luajit
LUAJIT_INC ?= $(LUAJIT_DIR)/src
LUAJIT_LIB ?= $(LUAJIT_DIR)/src/libluajit.a
BUILD_MODE ?= release

BASE_CFLAGS := -Wall -Wextra -I. -MMD -MP

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
	CFLAGS := $(BASE_CFLAGS) -O0 -g -DDEBUG
else ifeq ($(BUILD_MODE),release)
	CFLAGS := $(BASE_CFLAGS) -O2 -DNDEBUG
else
	$(error Unsupported BUILD_MODE '$(BUILD_MODE)'; expected 'debug' or 'release')
endif

OBJ_DIR := obj
BIN_DIR := bin

TARGET_LIB := lib$(LIB_NAME).a
CORE_SRCS := xargs.c xpoll.c xsock.c xchannel.c xthread.c xtimer.c
CORE_OBJS := $(addprefix $(OBJ_DIR)/,$(CORE_SRCS:.c=.o))
CORE_DEPS := $(CORE_OBJS:.o=.d)

EXE_EXT :=
SYS_LDFLAGS :=
RM := rm -rf
MKDIR := mkdir -p
MV := mv -f

ifeq ($(OS),Windows_NT)
	EXE_EXT := .exe
	SYS_LDFLAGS += -lws2_32
	RM := /usr/bin/rm -rf
	MV := /usr/bin/mv -f
else
	SYS_LDFLAGS += -lpthread -lm
endif

XNET_DEFS := -DXNET_WITH_HTTP=$(WITH_HTTP) -DXNET_WITH_HTTPS=$(WITH_HTTPS)
XNET_CFLAGS :=
XNET_HTTPS_SRC :=
XNET_UTIL_SRC := 3rd/yyjson.c xlua/lua_xutils.c
XNET_LUA_SRC := xlua/lua_xthread.c xlua/lua_xnet.c xlua/lua_xnet_tls.c xlua/lua_cmsgpack.c xlua/lua_xtimer.c
XNET_LUA_LIB :=
XNET_EXTRA_LDFLAGS :=
XNET_BUILD := $(BIN_DIR)/xnet_build$(EXE_EXT)
XNET_TARGET := $(BIN_DIR)/xnet$(EXE_EXT)

# rpmalloc is consumed by everything that uses libxsock.a or compiles xthread.c
# directly. libxsock.a itself does NOT contain rpmalloc symbols, so both the
# xnet target and the xthread_test target add it to their own source lists.
# Empty when WITH_RPMALLOC=0 — xmacro.h then stubs the lifecycle API.
ifeq ($(WITH_RPMALLOC),1)
    RPMALLOC_SRC := 3rd/rpmalloc/rpmalloc.c
else
    RPMALLOC_SRC :=
endif

XTHREAD_TEST_SRCS := demo/xthread_test.c xthread.c xpoll.c xsock.c $(RPMALLOC_SRC)
XTHREAD_TEST_BUILD := $(BIN_DIR)/xthread_test_build$(EXE_EXT)
XTHREAD_TEST_TARGET := $(BIN_DIR)/xthread_test$(EXE_EXT)

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

ifeq ($(WITH_IO_URING),1)
ifneq ($(OS),Windows_NT)
	CFLAGS += -DXPOLL_USE_IO_URING -DXCHANNEL_USE_IO_URING
	SYS_LDFLAGS += -luring
endif
endif

ifeq ($(WITH_HTTPS),1)
	XNET_CFLAGS += -I3rd/mbedtls3/include
	XNET_HTTPS_SRC := $(wildcard 3rd/mbedtls3/library/*.c)
ifeq ($(OS),Windows_NT)
	SYS_LDFLAGS += -lbcrypt
endif
endif

.PHONY: all xnet xthread_test clean test test-c test-lua-core test-lua-external test-lua-all run-lua

all: $(TARGET_LIB) $(XNET_TARGET) $(XTHREAD_TEST_TARGET)

xnet: $(XNET_TARGET)

xthread_test: $(XTHREAD_TEST_TARGET)

$(TARGET_LIB): $(CORE_OBJS)
	$(AR) $(ARFLAGS) $@ $(CORE_OBJS)

$(OBJ_DIR)/%.o: %.c | $(OBJ_DIR)
	$(CC) $(CFLAGS) -c $< -o $@

$(XNET_TARGET): xnet_main.c $(XNET_LUA_SRC) $(XNET_UTIL_SRC) $(RPMALLOC_SRC) $(TARGET_LIB) $(XNET_HTTPS_SRC) $(XNET_LUA_LIB) | $(BIN_DIR)
	$(RM) $(XNET_BUILD)
	$(CC) $(CFLAGS) $(XNET_CFLAGS) $(XNET_DEFS) -o $(XNET_BUILD) xnet_main.c $(XNET_LUA_SRC) $(XNET_UTIL_SRC) $(XNET_HTTPS_SRC) $(RPMALLOC_SRC) $(TARGET_LIB) $(XNET_LUA_LIB) $(SYS_LDFLAGS) $(XNET_EXTRA_LDFLAGS)
	$(MV) $(XNET_BUILD) $(XNET_TARGET)

$(XTHREAD_TEST_TARGET): $(XTHREAD_TEST_SRCS) | $(BIN_DIR)
	$(RM) $(XTHREAD_TEST_BUILD)
	$(CC) $(CFLAGS) -I. -o $(XTHREAD_TEST_BUILD) $(XTHREAD_TEST_SRCS) $(SYS_LDFLAGS)
	$(MV) $(XTHREAD_TEST_BUILD) $(XTHREAD_TEST_TARGET)

$(OBJ_DIR):
	$(MKDIR) $(OBJ_DIR)

$(BIN_DIR):
	$(MKDIR) $(BIN_DIR)

test: test-c test-lua-core

test-c: $(XTHREAD_TEST_TARGET)
	$(XTHREAD_TEST_TARGET)

test-lua-core: $(XNET_TARGET)
	@set -e; \
	for script in $(LUA_TEST_CORE_SCRIPTS); do \
		echo "==> $$script"; \
		$(XNET_TARGET) $$script; \
	done

test-lua-external: $(XNET_TARGET)
	@set -e; \
	for script in $(LUA_TEST_EXTERNAL_SCRIPTS); do \
		echo "==> $$script"; \
		$(XNET_TARGET) $$script; \
	done

test-lua-all: test-lua-core test-lua-external

run-lua: $(XNET_TARGET)
	@if [ -z "$(SCRIPT)" ]; then \
		echo "Usage: make run-lua SCRIPT=demo/xutils_main.lua"; \
		exit 1; \
	fi
	$(XNET_TARGET) $(SCRIPT)

clean:
	$(RM) $(OBJ_DIR) $(TARGET_LIB) $(XNET_BUILD) $(XNET_TARGET) $(XTHREAD_TEST_BUILD) $(XTHREAD_TEST_TARGET)

-include $(CORE_DEPS)
