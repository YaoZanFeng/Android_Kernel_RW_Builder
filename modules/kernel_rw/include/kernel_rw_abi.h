/*
 * Shared kernel-side ioctl ABI for kernel_rw.
 *
 * Offset and size comments document the fixed 64-bit layout expected by the
 * userspace client and must stay in sync with that client.
 */
#ifndef KERNEL_RW_ABI_H
#define KERNEL_RW_ABI_H

#include <linux/types.h>

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

typedef struct _COPY_MEMORY {
    pid_t pid;             /* +0x00 */
    uintptr_t addr;        /* +0x08 */
    void __user *buffer;   /* +0x10 */
    size_t size;           /* +0x18 */
} COPY_MEMORY;             /* sizeof = 0x20 */

typedef struct _MODULE_BASE {
    pid_t pid;             /* +0x00 */
    char __user *name;     /* +0x08 */
    uintptr_t base;        /* +0x10 */
} MODULE_BASE;             /* sizeof = 0x18 */

typedef struct _TRACKING_DATA {
    bool is_active;        /* +0x00 */
    uintptr_t bp_addr;     /* +0x08 */
    float x;               /* +0x10 */
    float y;               /* +0x14 */
    float z;               /* +0x18 */
} TRACKING_DATA;           /* sizeof = 0x20 */

typedef struct _HW_BP_INFO {
    pid_t pid;                      /* +0x000 */
    uintptr_t addr;                 /* +0x008 */
    int type;                       /* +0x010 */
    int len;                        /* +0x014 */
    bool is_write_gp_regs;          /* +0x018 */
    int gp_reg_count;               /* +0x01c */
    int gp_reg_indices[10];         /* +0x020 */
    __u64 gp_reg_values[10];        /* +0x048 */
    bool is_write_fp_regs;          /* +0x098 */
    int fp_reg_count;               /* +0x09c */
    int fp_reg_indices[10];         /* +0x0a0 */
    __u64 fp_reg_values[10][2];     /* +0x0c8 */
} HW_BP_INFO;                       /* sizeof = 0x168 */

typedef struct REGS_INFO {
    __u64 regs[31];        /* +0x000 */
    __u64 sp;              /* +0x0f8 */
    __u64 pc;              /* +0x100 */
    __u64 pstate;          /* +0x108 */
} REGS_INFO;               /* sizeof = 0x110 */

typedef struct HWBP_HIT_ITEM {
    pid_t task_id;         /* +0x000 */
    uintptr_t hit_addr;    /* +0x008 */
    __u64 hit_time;        /* +0x010 */
    REGS_INFO regs_info;   /* +0x018 */
} HWBP_HIT_ITEM;           /* sizeof = 0x128 */

typedef struct _HWBP_HIT_ARGS {
    pid_t pid;                    /* +0x00 */
    uintptr_t addr;               /* +0x08 */
    HWBP_HIT_ITEM __user *out_buf; /* +0x10 */
    int out_len;                  /* +0x18 */
    int real_count;               /* +0x1c */
} HWBP_HIT_ARGS;                   /* sizeof = 0x20 */

#endif
