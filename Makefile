LIB_NAME := xsock
CC ?= gcc
AR ?= ar
ARFLAGS ?= rcs

CFLAGS := -Wall -Wextra -O2 -I. -MMD -MP
WITH_IO_URING ?= 0
WITH_HTTP ?= 1
WITH_HTTPS ?= 1

OBJ_DIR := obj
BIN_DIR := bin

TARGET_LIB := lib$(LIB_NAME).a
SRCS := xargs.c xpoll.c xsock.c xchannel.c xthread.c xtimer.c
OBJS := $(addprefix $(OBJ_DIR)/,$(SRCS:.c=.o))
DEPS := $(OBJS:.o=.d)

XNET_DEFS := -DLUA_EMBEDDED -DXNET_WITH_HTTP=$(WITH_HTTP) -DXNET_WITH_HTTPS=$(WITH_HTTPS)
XNET_CFLAGS :=
XNET_HTTPS_SRC :=
XNET_UTIL_SRC := 3rd/yyjson.c xlua/lua_xutils.c
XNET_LUA_SRC := xlua/lua_xthread.c xlua/lua_xnet.c xlua/lua_xnet_tls.c xlua/lua_cmsgpack.c xlua/lua_xtimer.c
XNET_BUILD := $(BIN_DIR)/xnet_build
XNET_TARGET := $(BIN_DIR)/xnet

LDFLAGS :=

ifeq ($(OS),Windows_NT)
    XNET_BUILD := $(XNET_BUILD).exe
    XNET_TARGET := $(XNET_TARGET).exe
    LDFLAGS += -lws2_32
    RM := /usr/bin/rm -rf
    MKDIR := mkdir -p
    MV := /usr/bin/mv -f
else
    LDFLAGS += -lpthread -lm
    RM := rm -rf
    MKDIR := mkdir -p
    MV := mv -f
endif

ifeq ($(WITH_IO_URING),1)
ifneq ($(OS),Windows_NT)
    CFLAGS += -DXPOLL_USE_IO_URING -DXCHANNEL_USE_IO_URING
    LDFLAGS += -luring
endif
endif

ifeq ($(WITH_HTTPS),1)
    XNET_CFLAGS += -I3rd/mbedtls3/include
    XNET_HTTPS_SRC := $(wildcard 3rd/mbedtls3/library/*.c)
ifeq ($(OS),Windows_NT)
    LDFLAGS += -lbcrypt
endif
endif

.PHONY: all clean

all: $(TARGET_LIB) $(XNET_TARGET)

$(TARGET_LIB): $(OBJS)
	$(AR) $(ARFLAGS) $@ $(OBJS)

$(OBJ_DIR)/%.o: %.c | $(OBJ_DIR)
	$(CC) $(CFLAGS) -c $< -o $@

$(XNET_TARGET): xnet_main.c $(XNET_LUA_SRC) $(XNET_UTIL_SRC) $(TARGET_LIB) $(XNET_HTTPS_SRC) | $(BIN_DIR)
	$(RM) $(XNET_BUILD)
	$(CC) $(CFLAGS) $(XNET_CFLAGS) $(XNET_DEFS) -o $(XNET_BUILD) xnet_main.c $(XNET_LUA_SRC) $(XNET_UTIL_SRC) $(XNET_HTTPS_SRC) $(TARGET_LIB) $(LDFLAGS)
	$(MV) $(XNET_BUILD) $(XNET_TARGET)

$(OBJ_DIR):
	$(MKDIR) $(OBJ_DIR)

$(BIN_DIR):
	$(MKDIR) $(BIN_DIR)

clean:
	$(RM) $(OBJ_DIR) $(TARGET_LIB) $(XNET_BUILD) $(XNET_TARGET)

-include $(DEPS)
