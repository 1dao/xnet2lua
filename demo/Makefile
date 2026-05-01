# Makefile for xthread test demo
# Supports both Linux and MinGW Windows

CC ?= gcc
CFLAGS := -Wall -Wextra -O0 -g -I..
#CFLAGS := -Wall -Wextra -O2 -I..
LDFLAGS :=
WITH_HTTP ?= 1
WITH_HTTPS ?= 1
XNET_DEFS := -DLUA_EMBEDDED -DXNET_WITH_HTTP=$(WITH_HTTP) -DXNET_WITH_HTTPS=$(WITH_HTTPS)
XNET_CFLAGS :=
XNET_HTTPS_SRC :=
XNET_UTIL_SRC := ../3rd/yyjson.c ../xlua/lua_xutils.c
MV := mv -f

ifeq ($(WITH_HTTPS),1)
    XNET_CFLAGS += -I../3rd/mbedtls3/include
    XNET_HTTPS_SRC := $(wildcard ../3rd/mbedtls3/library/*.c)
endif

# OS detection
ifeq ($(OS),Windows_NT)
    # MinGW on Windows
    LDFLAGS += -lws2_32
    ifeq ($(WITH_HTTPS),1)
        LDFLAGS += -lbcrypt
    endif
    EXT := .exe
    RM := /usr/bin/rm -f
    MV := /usr/bin/mv -f
else
    # Linux
    LDFLAGS += -lpthread
    EXT :=
    RM := rm -f
endif

# Targets
TARGET := xthread_test$(EXT)
XNET_TARGET := xnet$(EXT)
XNET_BUILD := xnet_build$(EXT)

all: $(TARGET) $(XNET_TARGET)

# Compile directly with all source files
$(TARGET): xthread_test.c ../xthread.c ../xpoll.c ../xsock.c
	$(CC) $(CFLAGS) -I.. -o $@ xthread_test.c ../xthread.c ../xpoll.c ../xsock.c $(LDFLAGS)

# Generic Lua runner - pass the Lua main file at runtime.
xnet$(EXT): xnet_main.c ../xthread.c ../xpoll.c ../xsock.c ../xchannel.c ../xargs.c ../xlua/lua_xthread.c ../xlua/lua_xnet.c ../xlua/lua_xnet_tls.c ../xlua/lua_xnet_tls.h ../xlua/lua_cmsgpack.c ../xlua/lua_xutils.c ../3rd/yyjson.c ../3rd/yyjson.h ../libxsock.a $(XNET_HTTPS_SRC)
	$(RM) $(XNET_BUILD)
	$(CC) $(CFLAGS) $(XNET_CFLAGS) $(XNET_DEFS) -I.. -o $(XNET_BUILD) xnet_main.c ../xthread.c ../xpoll.c ../xsock.c ../xchannel.c ../xargs.c ../xlua/lua_xthread.c ../xlua/lua_xnet.c ../xlua/lua_xnet_tls.c ../xlua/lua_cmsgpack.c $(XNET_UTIL_SRC) $(XNET_HTTPS_SRC) ../libxsock.a $(LDFLAGS)
	$(MV) $(XNET_BUILD) $@

clean:
	$(RM) $(TARGET) $(XNET_TARGET) $(XNET_BUILD) xlua_test$(EXT) xnet_test$(EXT) xredis_test$(EXT) *.o

.PHONY: all clean
