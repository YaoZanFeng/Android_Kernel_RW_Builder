CC = clang
AR = llvm-ar
CFLAGS ?= -O2 -Wall -Wextra -Wpedantic -std=c11

.PHONY: all clean

all: libkernel_rw.a kernel_rw_test

kernel_rw_client.o: kernel_rw_client.c kernel_rw_client.h
	$(CC) $(CFLAGS) -c $< -o $@

kernel_rw_test.o: kernel_rw_test.c kernel_rw_client.h
	$(CC) $(CFLAGS) -c $< -o $@

libkernel_rw.a: kernel_rw_client.o
	$(AR) rcs $@ $^

kernel_rw_test: kernel_rw_test.o libkernel_rw.a
	$(CC) $(CFLAGS) kernel_rw_test.o -L. -lkernel_rw -o $@

clean:
	rm -f kernel_rw_client.o kernel_rw_test.o libkernel_rw.a kernel_rw_test
