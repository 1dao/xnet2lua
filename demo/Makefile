# Makefile for xthread test demo
# Supports both Linux and MinGW Windows

CC ?= gcc
CFLAGS := -Wall -Wextra -O0 -g -I..
#CFLAGS := -Wall -Wextra -O2 -I..
LDFLAGS :=

# OS detection
ifeq ($(OS),Windows_NT)
    # MinGW on Windows
    LDFLAGS += -lws2_32
    EXT := .exe
    RM := /usr/bin/rm -f
else
    # Linux
    LDFLAGS += -lpthread
    EXT :=
    RM := rm -f
endif

# Targets
TARGET := xthread_test$(EXT)
XNET_TARGET := xnet$(EXT)

all: $(TARGET) $(XNET_TARGET)

# Compile directly with all source files
$(TARGET): xthread_test.c ../xthread.c ../xpoll.c ../xsock.c
	$(CC) $(CFLAGS) -I.. -o $@ xthread_test.c ../xthread.c ../xpoll.c ../xsock.c $(LDFLAGS)

# Generic Lua runner - pass the Lua main file at runtime.
xnet$(EXT): xnet_main.c ../xthread.c ../xpoll.c ../xsock.c ../xchannel.c ../xargs.c ../xlua/lua_xthread.c ../xlua/lua_xnet.c ../xlua/lua_cmsgpack.c ../libxsock.a
	$(CC) $(CFLAGS) -DLUA_EMBEDDED -I.. -o $@ xnet_main.c ../xthread.c ../xpoll.c ../xsock.c ../xchannel.c ../xargs.c ../xlua/lua_xthread.c ../xlua/lua_xnet.c ../xlua/lua_cmsgpack.c ../libxsock.a $(LDFLAGS)

clean:
	$(RM) $(TARGET) $(XNET_TARGET) xlua_test$(EXT) xnet_test$(EXT) xredis_test$(EXT) *.o

.PHONY: all clean
