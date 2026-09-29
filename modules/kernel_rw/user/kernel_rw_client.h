#ifndef KERNEL_RW_CLIENT_H
#define KERNEL_RW_CLIENT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#define KERNEL_RW_IOCTL_BASE 0x03186751u

enum kernel_rw_ioctl_command {
    KERNEL_RW_IOCTL_INSTALL_HW_BP     = KERNEL_RW_IOCTL_BASE + 0,
    KERNEL_RW_IOCTL_GET_HW_BP_HITS    = KERNEL_RW_IOCTL_BASE + 1,
    KERNEL_RW_IOCTL_ENABLE_HW_BP      = KERNEL_RW_IOCTL_BASE + 2,
    KERNEL_RW_IOCTL_CLEAR_ALL_HW_BPS  = KERNEL_RW_IOCTL_BASE + 3,
    KERNEL_RW_IOCTL_DISABLE_HW_BP     = KERNEL_RW_IOCTL_BASE + 4,
    KERNEL_RW_IOCTL_SET_TRACKING_DATA = KERNEL_RW_IOCTL_BASE + 5,
    KERNEL_RW_IOCTL_READ_MEMORY       = KERNEL_RW_IOCTL_BASE + 8,
    KERNEL_RW_IOCTL_WRITE_MEMORY      = KERNEL_RW_IOCTL_BASE + 15,
    KERNEL_RW_IOCTL_MODULE_BASE       = KERNEL_RW_IOCTL_BASE + 16,
};

typedef struct kernel_rw_copy_memory {
    pid_t pid;
    uintptr_t addr;
    void *buffer;
    size_t size;
} kernel_rw_copy_memory;

typedef struct kernel_rw_module_base {
    pid_t pid;
    char *name;
    uintptr_t base;
} kernel_rw_module_base;

_Static_assert(sizeof(void *) == 8,
               "this driver ABI requires a 64-bit userspace process");
_Static_assert(sizeof(pid_t) == 4, "unexpected pid_t size");
_Static_assert(sizeof(kernel_rw_copy_memory) == 0x20,
               "COPY_MEMORY ABI mismatch");
_Static_assert(offsetof(kernel_rw_copy_memory, addr) == 0x08,
               "COPY_MEMORY.addr ABI mismatch");
_Static_assert(offsetof(kernel_rw_copy_memory, buffer) == 0x10,
               "COPY_MEMORY.buffer ABI mismatch");
_Static_assert(offsetof(kernel_rw_copy_memory, size) == 0x18,
               "COPY_MEMORY.size ABI mismatch");
_Static_assert(sizeof(kernel_rw_module_base) == 0x18,
               "MODULE_BASE ABI mismatch");

int kernel_rw_open(const char *device_path);
int kernel_rw_read_memory(int fd, pid_t pid, uintptr_t remote_addr,
                          void *local_buffer, size_t size);
int kernel_rw_write_memory(int fd, pid_t pid, uintptr_t remote_addr,
                           const void *local_buffer, size_t size);
int kernel_rw_find_module_base(int fd, pid_t pid, const char *module_name,
                               uintptr_t *base_out);

#endif
