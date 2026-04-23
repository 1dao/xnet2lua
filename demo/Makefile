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
else
    # Linux
    LDFLAGS += -lpthread
    EXT :=
endif

# Targets
TARGET := xthread_test$(EXT)
XLUA_TARGET := xlua_test$(EXT)

all: $(TARGET) $(XLUA_TARGET)

# Compile directly with all source files
$(TARGET): xthread_test.c ../xthread.c ../xpoll.c ../xsock.c
	$(CC) $(CFLAGS) -I.. -o $@ xthread_test.c ../xthread.c ../xpoll.c ../xsock.c $(LDFLAGS)

# xthread Lua test - uses embedded minilua.h from 3rd/
# No external Lua dependency required - cmsgpack is statically linked
xlua_test$(EXT): xlua_test.c ../xthread.c ../xpoll.c ../xlua/lua_xthread.c ../xlua/lua_cmsgpack.c ../libxsock.a
	$(CC) $(CFLAGS) -DLUA_EMBEDDED -I.. -o $@ xlua_test.c ../xthread.c ../xpoll.c ../xlua/lua_xthread.c ../xlua/lua_cmsgpack.c ../libxsock.a $(LDFLAGS)

clean:
	rm -f $(TARGET) $(XLUA_TARGET) *.o

.PHONY: all clean
