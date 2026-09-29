/*
 * ARM64 hardware-breakpoint support for kernel_rw.
 *
 * Breakpoints are registered through the perf-event hardware-breakpoint API.
 * Per-breakpoint state tracks optional register writes and the hit ring exposed
 * through the ioctl ABI.
 */
#include <linux/errno.h>
#include <linux/hw_breakpoint.h>
#include <linux/list.h>
#include <linux/mutex.h>
#include <linux/perf_event.h>
#include <linux/pid.h>
#include <linux/sched.h>
#include <linux/slab.h>
#include <linux/spinlock.h>
#include <linux/uaccess.h>

#include "../include/kernel_rw_abi.h"

#define MAX_WRITE_REGS 10
#define HIT_RING_SIZE 16

typedef struct perf_event *(*register_user_hw_breakpoint_t)(
    struct perf_event_attr *,
    void (*)(struct perf_event *, struct perf_sample_data *, struct pt_regs *),
    void *, struct task_struct *);
typedef void (*unregister_hw_breakpoint_t)(struct perf_event *);
typedef int (*modify_user_hw_breakpoint_t)(struct perf_event *,
                                           struct perf_event_attr *);
typedef void (*fpsimd_save_t)(void);
typedef void (*fpsimd_flush_t)(struct task_struct *);

struct hw_bp_context {
    struct list_head list;                 /* +0x0000 */
    pid_t pid;                             /* +0x0010 */
    uintptr_t addr;                        /* +0x0018 */
    struct perf_event *pe;                 /* +0x0020 */
    int type;                              /* +0x0028 */
    int len;                               /* +0x002c */
    bool is_stepping;                      /* +0x0030 */
    bool is_write_gp_regs;                 /* +0x0031 */
    int gp_reg_count;                      /* +0x0034 */
    int gp_reg_indices[MAX_WRITE_REGS];    /* +0x0038 */
    uint64_t gp_reg_values[MAX_WRITE_REGS]; /* +0x0060 */
    bool is_write_fp_regs;                 /* +0x00b0 */
    int fp_reg_count;                      /* +0x00b4 */
    int fp_reg_indices[MAX_WRITE_REGS];    /* +0x00b8 */
    uint64_t fp_reg_values[MAX_WRITE_REGS][2]; /* +0x00e0 */
    HWBP_HIT_ITEM hit_records[HIT_RING_SIZE];  /* +0x0180 */
    int head;                              /* +0x1400 */
    int tail;                              /* +0x1404 */
    int count;                             /* +0x1408 */
    spinlock_t lock;                       /* +0x140c */
};                                        /* sizeof = 0x1410 */

extern unsigned long util_kallsyms_lookup_name(const char *name);
extern TRACKING_DATA g_tracking_data;

static register_user_hw_breakpoint_t _register_user_hw_breakpoint;
static unregister_hw_breakpoint_t _unregister_hw_breakpoint;
static modify_user_hw_breakpoint_t _modify_user_hw_breakpoint;
static fpsimd_save_t _fpsimd_save;
static fpsimd_flush_t _fpsimd_flush;

static DEFINE_MUTEX(g_bp_mutex);
static LIST_HEAD(g_bp_list);

/*
 * ARM64 debug-register banks addressed by the switch below:
 *   0..15  DBGBVR<n>_EL1    16..31 DBGBCR<n>_EL1
 *   32..47 DBGWVR<n>_EL1    48..63 DBGWCR<n>_EL1
 */
#define MRS_CASE(number, sysreg) \
    case number: asm volatile("mrs %0, " #sysreg : "=r"(val)); break

static uint64_t read_wb_reg(int reg, int n)
{
    uint64_t val = 0;

    switch (reg + n) {
    MRS_CASE(0,  dbgbvr0_el1);  MRS_CASE(1,  dbgbvr1_el1);
    MRS_CASE(2,  dbgbvr2_el1);  MRS_CASE(3,  dbgbvr3_el1);
    MRS_CASE(4,  dbgbvr4_el1);  MRS_CASE(5,  dbgbvr5_el1);
    MRS_CASE(6,  dbgbvr6_el1);  MRS_CASE(7,  dbgbvr7_el1);
    MRS_CASE(8,  dbgbvr8_el1);  MRS_CASE(9,  dbgbvr9_el1);
    MRS_CASE(10, dbgbvr10_el1); MRS_CASE(11, dbgbvr11_el1);
    MRS_CASE(12, dbgbvr12_el1); MRS_CASE(13, dbgbvr13_el1);
    MRS_CASE(14, dbgbvr14_el1); MRS_CASE(15, dbgbvr15_el1);
    MRS_CASE(16, dbgbcr0_el1);  MRS_CASE(17, dbgbcr1_el1);
    MRS_CASE(18, dbgbcr2_el1);  MRS_CASE(19, dbgbcr3_el1);
    MRS_CASE(20, dbgbcr4_el1);  MRS_CASE(21, dbgbcr5_el1);
    MRS_CASE(22, dbgbcr6_el1);  MRS_CASE(23, dbgbcr7_el1);
    MRS_CASE(24, dbgbcr8_el1);  MRS_CASE(25, dbgbcr9_el1);
    MRS_CASE(26, dbgbcr10_el1); MRS_CASE(27, dbgbcr11_el1);
    MRS_CASE(28, dbgbcr12_el1); MRS_CASE(29, dbgbcr13_el1);
    MRS_CASE(30, dbgbcr14_el1); MRS_CASE(31, dbgbcr15_el1);
    MRS_CASE(32, dbgwvr0_el1);  MRS_CASE(33, dbgwvr1_el1);
    MRS_CASE(34, dbgwvr2_el1);  MRS_CASE(35, dbgwvr3_el1);
    MRS_CASE(36, dbgwvr4_el1);  MRS_CASE(37, dbgwvr5_el1);
    MRS_CASE(38, dbgwvr6_el1);  MRS_CASE(39, dbgwvr7_el1);
    MRS_CASE(40, dbgwvr8_el1);  MRS_CASE(41, dbgwvr9_el1);
    MRS_CASE(42, dbgwvr10_el1); MRS_CASE(43, dbgwvr11_el1);
    MRS_CASE(44, dbgwvr12_el1); MRS_CASE(45, dbgwvr13_el1);
    MRS_CASE(46, dbgwvr14_el1); MRS_CASE(47, dbgwvr15_el1);
    MRS_CASE(48, dbgwcr0_el1);  MRS_CASE(49, dbgwcr1_el1);
    MRS_CASE(50, dbgwcr2_el1);  MRS_CASE(51, dbgwcr3_el1);
    MRS_CASE(52, dbgwcr4_el1);  MRS_CASE(53, dbgwcr5_el1);
    MRS_CASE(54, dbgwcr6_el1);  MRS_CASE(55, dbgwcr7_el1);
    MRS_CASE(56, dbgwcr8_el1);  MRS_CASE(57, dbgwcr9_el1);
    MRS_CASE(58, dbgwcr10_el1); MRS_CASE(59, dbgwcr11_el1);
    MRS_CASE(60, dbgwcr12_el1); MRS_CASE(61, dbgwcr13_el1);
    MRS_CASE(62, dbgwcr14_el1); MRS_CASE(63, dbgwcr15_el1);
    default:
        pr_warn("attempt to read from unknown breakpoint register %d\n", n);
        break;
    }
    return val;
}

#undef MRS_CASE

/*
 * Locate the architectural breakpoint/watchpoint slot that matches bp_addr.
 * The active install path uses perf events; this helper only validates the
 * matching slot and keeps the required instruction-synchronization barrier.
 */
bool toggle_bp_registers_directly(const struct perf_event_attr *attr,
                                  bool is_32bit_task, int enable)
{
    uint64_t wanted;
    int value_bank;
    int control_bank;
    int max_slots;
    int slot;

    if (!attr)
        return false;

    if (is_32bit_task) {
        wanted = attr->bp_addr & ~7ULL;
        value_bank = 32;
        control_bank = 48;
        max_slots = 2 + 1; /* Watchpoint slots represented by this path. */
    } else {
        wanted = attr->bp_addr & ~3ULL;
        value_bank = 0;
        control_bank = 16;
        max_slots = 4 + 1; /* Breakpoint slots represented by this path. */
    }

    for (slot = 0; slot < max_slots; ++slot) {
        if (read_wb_reg(value_bank, slot) == wanted)
            break;
    }
    if (slot == max_slots)
        return false;

    /*
     * Direct control/value-register writes are intentionally not duplicated
     * here; normal installation and updates are handled through perf events.
     */
    (void)control_bank;
    (void)enable;
    asm volatile("isb" ::: "memory");
    return true;
}

static void write_fp_dreg(unsigned int reg, uint64_t value)
{
#define FMOV_CASE(n) \
    case n: \
        asm volatile(".arch_extension fp\n\t" \
                     "fmov d" #n ", %0\n\t" \
                     ".arch_extension nofp" \
                     :: "r"(value)); \
        break
    switch (reg) {
    FMOV_CASE(0);  FMOV_CASE(1);  FMOV_CASE(2);  FMOV_CASE(3);
    FMOV_CASE(4);  FMOV_CASE(5);  FMOV_CASE(6);  FMOV_CASE(7);
    FMOV_CASE(8);  FMOV_CASE(9);  FMOV_CASE(10); FMOV_CASE(11);
    FMOV_CASE(12); FMOV_CASE(13); FMOV_CASE(14); FMOV_CASE(15);
    FMOV_CASE(16); FMOV_CASE(17); FMOV_CASE(18); FMOV_CASE(19);
    FMOV_CASE(20); FMOV_CASE(21); FMOV_CASE(22); FMOV_CASE(23);
    FMOV_CASE(24); FMOV_CASE(25); FMOV_CASE(26); FMOV_CASE(27);
    FMOV_CASE(28); FMOV_CASE(29); FMOV_CASE(30);
    default:
        break;
    }
#undef FMOV_CASE
}

static void hw_bp_handler(struct perf_event *bp,
                          struct perf_sample_data *data,
                          struct pt_regs *regs)
{
    struct hw_bp_context *ctx;
    bool tracking_match;
    int i;

    (void)data;
    if (!regs)
        return;

    ctx = bp->overflow_handler_context;
    if (!ctx)
        return;

    if (ctx->is_write_gp_regs &&
        ctx->gp_reg_count > 0 && ctx->gp_reg_count <= MAX_WRITE_REGS) {
        for (i = 0; i < ctx->gp_reg_count; ++i) {
            const int index = ctx->gp_reg_indices[i];
            if (index >= 0 && index < 31)
                regs->regs[index] = ctx->gp_reg_values[i];
        }
    }

    tracking_match = g_tracking_data.bp_addr &&
                     ctx->addr == g_tracking_data.bp_addr;

    if (ctx->is_write_fp_regs &&
        ctx->fp_reg_count > 0 && ctx->fp_reg_count <= MAX_WRITE_REGS) {
        for (i = 0; i < ctx->fp_reg_count; ++i) {
            uint64_t value = ctx->fp_reg_values[i][0];
            const int index = ctx->fp_reg_indices[i];

            if (tracking_match && g_tracking_data.is_active && i < 3) {
                const uint32_t replacement[3] = {
                    *(__u32 *)&g_tracking_data.x,
                    *(__u32 *)&g_tracking_data.y,
                    *(__u32 *)&g_tracking_data.z,
                };
                value = (value & 0xffffffff00000000ULL) | replacement[i];
            }

            if (index >= 0 && index < 31)
                write_fp_dreg(index, value);
        }
    }

    if (_modify_user_hw_breakpoint) {
        struct perf_event_attr attr = bp->attr;

        attr.disabled = 0;
        if (ctx->is_stepping) {
            attr.bp_addr = ctx->addr;
            ctx->is_stepping = false;
        } else {
            attr.bp_addr = ctx->addr + 4;
            ctx->is_stepping = true;
        }
        _modify_user_hw_breakpoint(bp, &attr);
    } else {
        ctx->is_stepping = !ctx->is_stepping;
    }

    /* This handler currently does not append entries to hit_records. */
}

static int resolve_hw_bp_symbols(void)
{
    if (_register_user_hw_breakpoint && _unregister_hw_breakpoint &&
        _modify_user_hw_breakpoint)
        return 0;

    _register_user_hw_breakpoint = (void *)util_kallsyms_lookup_name(
        "register_user_hw_breakpoint");
    _unregister_hw_breakpoint = (void *)util_kallsyms_lookup_name(
        "unregister_hw_breakpoint");
    _modify_user_hw_breakpoint = (void *)util_kallsyms_lookup_name(
        "modify_user_hw_breakpoint");
    _fpsimd_save = (void *)util_kallsyms_lookup_name("fpsimd_save");
    if (!_fpsimd_save)
        _fpsimd_save = (void *)util_kallsyms_lookup_name(
            "fpsimd_preserve_current_state");
    _fpsimd_flush = (void *)util_kallsyms_lookup_name(
        "fpsimd_flush_task_state");

    if (!_register_user_hw_breakpoint || !_unregister_hw_breakpoint ||
        !_modify_user_hw_breakpoint) {
        pr_err("[HWBP] Core symbols not found\n");
        return -ENXIO;
    }
    return 0;
}

static void copy_write_configuration(struct hw_bp_context *ctx,
                                     const HW_BP_INFO *info)
{
    int i;

    ctx->is_write_gp_regs = info->is_write_gp_regs;
    ctx->gp_reg_count = clamp(info->gp_reg_count, 0, MAX_WRITE_REGS);
    for (i = 0; i < ctx->gp_reg_count; ++i) {
        ctx->gp_reg_indices[i] = info->gp_reg_indices[i];
        ctx->gp_reg_values[i] = info->gp_reg_values[i];
    }

    ctx->is_write_fp_regs = info->is_write_fp_regs;
    ctx->fp_reg_count = clamp(info->fp_reg_count, 0, MAX_WRITE_REGS);
    for (i = 0; i < ctx->fp_reg_count; ++i) {
        ctx->fp_reg_indices[i] = info->fp_reg_indices[i];
        ctx->fp_reg_values[i][0] = info->fp_reg_values[i][0];
        ctx->fp_reg_values[i][1] = info->fp_reg_values[i][1];
    }
}

int install_hw_bp(HW_BP_INFO *info)
{
    struct perf_event_attr attr;
    struct task_struct *task;
    struct hw_bp_context *ctx;
    struct hw_bp_context *pos;
    int ret;

    ret = resolve_hw_bp_symbols();
    if (ret)
        return ret;

    mutex_lock(&g_bp_mutex);
    list_for_each_entry(pos, &g_bp_list, list) {
        if (pos->pid == info->pid && pos->addr == info->addr) {
            mutex_unlock(&g_bp_mutex);
            return -EEXIST;
        }
    }

    hw_breakpoint_init(&attr);
    attr.type = PERF_TYPE_BREAKPOINT;
    attr.size = sizeof(attr);
    attr.pinned = 1;
    attr.bp_addr = info->addr;
    attr.bp_len = info->len;
    attr.bp_type = (info->type >= 1 && info->type <= 4) ?
        info->type : HW_BREAKPOINT_RW;

    task = get_pid_task(find_vpid(info->pid), PIDTYPE_PID);
    if (!task) {
        mutex_unlock(&g_bp_mutex);
        return -ESRCH;
    }

    ctx = kzalloc(sizeof(*ctx), GFP_KERNEL);
    if (!ctx) {
        put_task_struct(task);
        mutex_unlock(&g_bp_mutex);
        return -ENOMEM;
    }

    ctx->pid = info->pid;
    ctx->addr = info->addr;
    ctx->type = info->type;
    ctx->len = info->len;
    copy_write_configuration(ctx, info);
    spin_lock_init(&ctx->lock);

    ctx->pe = _register_user_hw_breakpoint(&attr, hw_bp_handler, ctx, task);
    put_task_struct(task);
    if (IS_ERR(ctx->pe)) {
        ret = PTR_ERR(ctx->pe);
        kfree(ctx);
        mutex_unlock(&g_bp_mutex);
        return ret;
    }

    list_add(&ctx->list, &g_bp_list);
    mutex_unlock(&g_bp_mutex);
    return 0;
}

int get_hw_bp_hits(HWBP_HIT_ARGS *args)
{
    struct hw_bp_context *ctx;
    HWBP_HIT_ITEM *copy;
    unsigned long flags;
    int count;
    int i;

    mutex_lock(&g_bp_mutex);
    list_for_each_entry(ctx, &g_bp_list, list) {
        if (ctx->pid != args->pid || ctx->addr != args->addr)
            continue;

        spin_lock_irqsave(&ctx->lock, flags);
        count = min(ctx->count, args->out_len);
        if (!count) {
            spin_unlock_irqrestore(&ctx->lock, flags);
            args->real_count = 0;
            mutex_unlock(&g_bp_mutex);
            return 0;
        }

        copy = kmalloc_array(count, sizeof(*copy), GFP_KERNEL);
        if (!copy) {
            spin_unlock_irqrestore(&ctx->lock, flags);
            mutex_unlock(&g_bp_mutex);
            return -ENOMEM;
        }

        for (i = 0; i < count; ++i) {
            copy[i] = ctx->hit_records[ctx->tail];
            ctx->tail = (ctx->tail + 1) & (HIT_RING_SIZE - 1);
        }
        ctx->count -= count;
        spin_unlock_irqrestore(&ctx->lock, flags);

        if (copy_to_user(args->out_buf, copy,
                         count * sizeof(*copy))) {
            kfree(copy);
            mutex_unlock(&g_bp_mutex);
            return -EFAULT;
        }

        args->real_count = count;
        kfree(copy);
        mutex_unlock(&g_bp_mutex);
        return 0;
    }

    mutex_unlock(&g_bp_mutex);
    return -ENOENT;
}

void clear_all_hw_bps(void)
{
    struct hw_bp_context *pos;
    struct hw_bp_context *next;

    mutex_lock(&g_bp_mutex);
    list_for_each_entry_safe(pos, next, &g_bp_list, list) {
        if (pos->pe)
            _unregister_hw_breakpoint(pos->pe);
        list_del(&pos->list);
        kfree(pos);
    }
    mutex_unlock(&g_bp_mutex);
}

int enable_hw_bp(HW_BP_INFO *info)
{
    struct hw_bp_context *ctx;

    mutex_lock(&g_bp_mutex);
    list_for_each_entry(ctx, &g_bp_list, list) {
        if (ctx->pid != info->pid || ctx->addr != info->addr)
            continue;

        copy_write_configuration(ctx, info);
        if (ctx->pe && ctx->pe->attr.disabled &&
            _modify_user_hw_breakpoint) {
            struct perf_event_attr attr = ctx->pe->attr;
            attr.disabled = 0;
            _modify_user_hw_breakpoint(ctx->pe, &attr);
        }
        mutex_unlock(&g_bp_mutex);
        return 0;
    }

    mutex_unlock(&g_bp_mutex);
    return -ENOENT;
}

int disable_hw_bp(pid_t pid, uintptr_t addr)
{
    struct hw_bp_context *ctx;

    mutex_lock(&g_bp_mutex);
    list_for_each_entry(ctx, &g_bp_list, list) {
        if (ctx->pid != pid || ctx->addr != addr)
            continue;

        if (!_modify_user_hw_breakpoint) {
            mutex_unlock(&g_bp_mutex);
            return -EIO;
        }

        if (ctx->pe) {
            struct perf_event_attr attr = ctx->pe->attr;
            attr.disabled = 1;
            _modify_user_hw_breakpoint(ctx->pe, &attr);
        }
        mutex_unlock(&g_bp_mutex);
        return 0;
    }

    mutex_unlock(&g_bp_mutex);
    return -ENOENT;
}
