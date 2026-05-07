# Unified demo build wrapper.
# Real build/test logic lives in the root Makefile.

.PHONY: all xnet xthread_test test test-c test-lua-core test-lua-external test-lua-all run-lua clean

all:
	$(MAKE) -C .. all

xnet:
	$(MAKE) -C .. xnet

xthread_test:
	$(MAKE) -C .. xthread_test

test:
	$(MAKE) -C .. test

test-c:
	$(MAKE) -C .. test-c

test-lua-core:
	$(MAKE) -C .. test-lua-core

test-lua-external:
	$(MAKE) -C .. test-lua-external

test-lua-all:
	$(MAKE) -C .. test-lua-all

run-lua:
	$(MAKE) -C .. run-lua SCRIPT=$(SCRIPT)

clean:
	$(MAKE) -C .. clean
