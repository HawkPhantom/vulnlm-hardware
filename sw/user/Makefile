CC ?= cc
CFLAGS ?= -O2 -g
CFLAGS += -std=c11 -Wall -Wextra -Werror -I../include
all: kv260ctl
kv260ctl: kv260ctl.c ../include/kv260_uapi.h ../include/kv260_contract.h
	$(CC) $(CFLAGS) -o $@ kv260ctl.c
test: kv260ctl
	./kv260ctl selftest
clean:
	rm -f kv260ctl
.PHONY: all test clean
