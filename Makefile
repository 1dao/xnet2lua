# 1. Project Settings
# Renamed from xproxy/xnet to xsock based on your request
LIB_NAME = xsock
CC = gcc
AR = ar
ARFLAGS = rcs
# -DXTHREAD_MPSCQ for using MPSCQ instead of the default queue implementation
# -MMD -MP for automatic header dependency tracking  
CFLAGS = -Wall -Wextra -O2 -I. -MMD -MP
WITH_IO_URING ?= 0

OBJ_DIR = obj

# 2. Platform Detection & Tool Setup
ifeq ($(OS), Windows_NT)
    TARGET_LIB = lib$(LIB_NAME).a
    # Detect if we are in a POSIX shell (like Git Bash) or CMD
    ifeq ($(findstring sh.exe,$(SHELL)),sh.exe)
        RM = rm -rf
        MKDIR = mkdir -p
    else
        RM = del /Q /F
        MKDIR = if not exist $@ mkdir
    endif
else
    TARGET_LIB = lib$(LIB_NAME).a
    RM = rm -rf
    MKDIR = mkdir -p
endif

ifeq ($(WITH_IO_URING),1)
ifneq ($(OS),Windows_NT)
    CFLAGS += -DXPOLL_USE_IO_URING -DXCHANNEL_USE_IO_URING
endif
endif

# 3. Source Files (Ensure these files exist in the same directory)
SRCS = xargs.c xpoll.c xsock.c xchannel.c xthread.c xtimer.c
OBJS = $(addprefix $(OBJ_DIR)/, $(notdir $(SRCS:.c=.o)))

# 4. Build Rules
.PHONY: all clean

all: $(TARGET_LIB)

# Link the library
$(TARGET_LIB): $(OBJS)
	$(AR) $(ARFLAGS) $@ $(OBJS)

# Compile source files to object files
# The '| $(OBJ_DIR)' ensures the directory exists before compilation
$(OBJ_DIR)/%.o: %.c | $(OBJ_DIR)
	$(CC) $(CFLAGS) -c $< -o $@

# Rule to create the object directory
$(OBJ_DIR):
	$(MKDIR) $(OBJ_DIR)

clean:
	$(RM) $(OBJ_DIR) $(TARGET_LIB)

# 5. Include dependencies
-include $(OBJS:.o=.d)
