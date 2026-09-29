/*
 * Process-memory translation and page-wise read/write helpers.
 *
 * Requests are split at page boundaries. A failed translation or userspace
 * copy does not stop the loop; the processed-byte count still advances for
 * each chunk. On writes, an uncopied tail in a valid mapping is zero-filled.
 */
#include <linux/mm.h>
#include <linux/pid.h>
#include <linux/sched/mm.h>
#include <linux/sched/task.h>
#include <linux/uaccess.h>

#include "../include/kernel_rw_abi.h"

static inline void *kernel_rw_phys_to_virt(phys_addr_t pa)
{
    return (void *)((pa - memstart_addr) | PAGE_OFFSET);
}

/* Translate a userspace virtual address to its backing physical address. */
phys_addr_t translate_linear_address_cache(struct mm_struct *mm, uintptr_t addr)
{
    pgd_t *pgdp;
    p4d_t *p4dp;
    pud_t *pudp;
    pmd_t *pmdp;
    pte_t *ptep;

    if (!mm)
        return 0;

    pgdp = pgd_offset(mm, addr);
    if (pgd_none(*pgdp))
        return 0;

    /* p4d/pud helpers also cover configurations where these levels are folded. */
    p4dp = p4d_offset(pgdp, addr);
    pudp = pud_offset(p4dp, addr);
    pmdp = pmd_offset(pudp, addr);
    if (pmd_none(*pmdp))
        return 0;

    if (pmd_sect(*pmdp))
        return (pmd_val(*pmdp) & 0xfffffffff000ULL) +
               (addr & ((1ULL << 21) - 1));

    if (!pmd_table(*pmdp))
        return 0;

    ptep = pte_offset_kernel(pmdp, addr);
    if (!pte_valid(*ptep))
        return 0;

    return (pte_val(*ptep) & 0xfffffffff000ULL) | (addr & (PAGE_SIZE - 1));
}

uint64_t read_process_memory(uint64_t pid, uint64_t addr,
                             uint64_t buffer, uint64_t size)
{
    uint64_t totalSize = 0;
    struct pid *ppid;
    struct task_struct *task;
    struct mm_struct *mm;

    ppid = find_get_pid((pid_t)pid);
    if (!ppid)
        return 0;

    task = get_pid_task(ppid, PIDTYPE_PID);
    put_pid(ppid);
    if (!task)
        return 0;

    mm = get_task_mm(task);
    put_task_struct(task);
    if (!mm)
        return 0;

    while (size) {
        const uint64_t read_size = min_t(uint64_t,
            PAGE_SIZE - (addr & (PAGE_SIZE - 1)), size);
        const phys_addr_t phy = translate_linear_address_cache(mm, addr);

        if (phy) {
            void *map_addr = kernel_rw_phys_to_virt(phy);
            check_object_size(map_addr, read_size, true);
            (void)copy_to_user((void __user *)(uintptr_t)buffer,
                               map_addr, read_size);
        }

        addr += read_size;
        buffer += read_size;
        size -= read_size;
        totalSize += read_size;
    }

    mmput(mm);
    return totalSize;
}

uint64_t write_process_memory(uint64_t pid, uint64_t addr,
                              uint64_t buffer, uint64_t size)
{
    uint64_t totalSize = 0;
    struct pid *ppid;
    struct task_struct *task;
    struct mm_struct *mm;

    ppid = find_get_pid((pid_t)pid);
    if (!ppid)
        return 0;

    task = get_pid_task(ppid, PIDTYPE_PID);
    put_pid(ppid);
    if (!task)
        return 0;

    mm = get_task_mm(task);
    put_task_struct(task);
    if (!mm)
        return 0;

    while (size) {
        const uint64_t read_size = min_t(uint64_t,
            PAGE_SIZE - (addr & (PAGE_SIZE - 1)), size);
        const phys_addr_t phy = translate_linear_address_cache(mm, addr);

        if (phy) {
            void *map_addr = kernel_rw_phys_to_virt(phy);
            unsigned long uncopied;

            check_object_size(map_addr, read_size, false);
            uncopied = copy_from_user(map_addr,
                (const void __user *)(uintptr_t)buffer, read_size);
            if (uncopied)
                memset((char *)map_addr + read_size - uncopied, 0, uncopied);
        }

        addr += read_size;
        buffer += read_size;
        size -= read_size;
        totalSize += read_size;
    }

    mmput(mm);
    return totalSize;
}
