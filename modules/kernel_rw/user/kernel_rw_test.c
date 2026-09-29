#include "kernel_rw_client.h"

#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void usage(const char *program)
{
    fprintf(stderr,
        "usage:\n"
        "  %s DEVICE read PID ADDRESS SIZE\n"
        "  %s DEVICE write-u64 PID ADDRESS VALUE\n"
        "  %s DEVICE module-base PID BASENAME\n",
        program, program, program);
}

static unsigned long long parse_u64(const char *text, const char *what)
{
    char *end = NULL;
    unsigned long long value;

    errno = 0;
    value = strtoull(text, &end, 0);
    if (errno || !end || *end != '\0') {
        fprintf(stderr, "invalid %s: %s\n", what, text);
        exit(2);
    }
    return value;
}

static void dump_hex(const unsigned char *data, size_t size)
{
    size_t offset;

    for (offset = 0; offset < size; offset += 16) {
        size_t i;
        printf("%08zx  ", offset);
        for (i = 0; i < 16; ++i) {
            if (offset + i < size)
                printf("%02x ", data[offset + i]);
            else
                printf("   ");
        }
        putchar('\n');
    }
}

int main(int argc, char **argv)
{
    const char *device_path;
    const char *command;
    pid_t pid;
    int fd;
    int status = 1;

    if (argc < 5) {
        usage(argv[0]);
        return 2;
    }

    device_path = argv[1];
    command = argv[2];
    pid = (pid_t)parse_u64(argv[3], "PID");

    fd = kernel_rw_open(device_path);
    if (fd < 0) {
        fprintf(stderr, "open %s: %s\n", device_path, strerror(errno));
        return 1;
    }

    if (!strcmp(command, "read") && argc == 6) {
        uintptr_t address = (uintptr_t)parse_u64(argv[4], "address");
        size_t size = (size_t)parse_u64(argv[5], "size");
        unsigned char *buffer;

        if (size == 0 || size > 1024 * 1024) {
            fprintf(stderr, "size must be between 1 and 1048576\n");
            goto out;
        }
        buffer = calloc(1, size);
        if (!buffer) {
            perror("calloc");
            goto out;
        }
        if (kernel_rw_read_memory(fd, pid, address, buffer, size) < 0) {
            fprintf(stderr, "read ioctl: %s\n", strerror(errno));
            free(buffer);
            goto out;
        }
        dump_hex(buffer, size);
        free(buffer);
        status = 0;
    } else if (!strcmp(command, "write-u64") && argc == 6) {
        uintptr_t address = (uintptr_t)parse_u64(argv[4], "address");
        uint64_t value = (uint64_t)parse_u64(argv[5], "value");

        if (kernel_rw_write_memory(fd, pid, address,
                                   &value, sizeof(value)) < 0) {
            fprintf(stderr, "write ioctl: %s\n", strerror(errno));
            goto out;
        }
        printf("wrote 0x%016" PRIx64 " to 0x%" PRIxPTR "\n",
               value, address);
        status = 0;
    } else if (!strcmp(command, "module-base") && argc == 5) {
        uintptr_t base;

        if (kernel_rw_find_module_base(fd, pid, argv[4], &base) < 0) {
            fprintf(stderr, "module-base ioctl: %s\n", strerror(errno));
            goto out;
        }
        printf("0x%" PRIxPTR "\n", base);
        status = 0;
    } else {
        usage(argv[0]);
        status = 2;
    }

out:
    close(fd);
    return status;
}
