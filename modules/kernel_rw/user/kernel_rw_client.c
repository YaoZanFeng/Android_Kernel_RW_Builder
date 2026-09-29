#define _GNU_SOURCE
#include "kernel_rw_client.h"

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

int kernel_rw_open(const char *device_path)
{
    if (!device_path) {
        errno = EINVAL;
        return -1;
    }
    return open(device_path, O_RDWR | O_CLOEXEC);
}

int kernel_rw_read_memory(int fd, pid_t pid, uintptr_t remote_addr,
                          void *local_buffer, size_t size)
{
    kernel_rw_copy_memory request = {
        .pid = pid,
        .addr = remote_addr,
        .buffer = local_buffer,
        .size = size,
    };

    if (fd < 0 || !local_buffer || size == 0) {
        errno = EINVAL;
        return -1;
    }
    return ioctl(fd, KERNEL_RW_IOCTL_READ_MEMORY, &request);
}

int kernel_rw_write_memory(int fd, pid_t pid, uintptr_t remote_addr,
                           const void *local_buffer, size_t size)
{
    kernel_rw_copy_memory request = {
        .pid = pid,
        .addr = remote_addr,
        .buffer = (void *)local_buffer,
        .size = size,
    };

    if (fd < 0 || !local_buffer || size == 0) {
        errno = EINVAL;
        return -1;
    }
    return ioctl(fd, KERNEL_RW_IOCTL_WRITE_MEMORY, &request);
}

int kernel_rw_find_module_base(int fd, pid_t pid, const char *module_name,
                               uintptr_t *base_out)
{
    char name_buffer[256] = { 0 };
    kernel_rw_module_base request = {
        .pid = pid,
        .name = name_buffer,
        .base = 0,
    };

    if (fd < 0 || !module_name || !base_out) {
        errno = EINVAL;
        return -1;
    }
    if (strnlen(module_name, sizeof(name_buffer)) >= sizeof(name_buffer) - 1) {
        errno = ENAMETOOLONG;
        return -1;
    }
    memcpy(name_buffer, module_name, strlen(module_name));
    if (ioctl(fd, KERNEL_RW_IOCTL_MODULE_BASE, &request) < 0)
        return -1;
    *base_out = request.base;
    return 0;
}
