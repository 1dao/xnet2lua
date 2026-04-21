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

# Target
TARGET := xthread_test$(EXT)

all: $(TARGET)

# Compile directly with all source files
$(TARGET): xthread_test.c ../xthread.c ../xpoll.c ../xsock.c
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

clean:
	rm -f $(TARGET) *.o

.PHONY: all clean
