/*
 * Character-device entry point and ioctl dispatcher for kernel_rw.
 *
 * This file owns the fixed /dev/kernel_rw node, resolves the kernel symbols
 * used by the module, and forwards requests to the memory and hardware-
 * breakpoint helpers.
 */
#include <linux/cdev.h>
#include <linux/device.h>
#include <linux/err.h>
#include <linux/fs.h>
#include <linux/kprobes.h>
#include <linux/mm.h>
#include <linux/module.h>
#include <linux/pid.h>
#include <linux/sched/mm.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/uaccess.h>

#include "../include/kernel_rw_abi.h"

uint64_t read_process_memory(uint64_t pid, uint64_t addr,
                             uint64_t buffer, uint64_t size);
uint64_t write_process_memory(uint64_t pid, uint64_t addr,
                              uint64_t buffer, uint64_t size);
int install_hw_bp(HW_BP_INFO *info);
int enable_hw_bp(HW_BP_INFO *info);
int disable_hw_bp(pid_t pid, uintptr_t addr);
int get_hw_bp_hits(HWBP_HIT_ARGS *args);
void clear_all_hw_bps(void);

TRACKING_DATA g_tracking_data;

static unsigned long (*kallsyms_lookup_name_fun_)(const char *name);
static struct kprobe kp_kallsyms = {
    .symbol_name = "kallsyms_lookup_name",
};

static dev_t mem_tool_dev_t;
static struct cdev memdev;
static struct class *mem_tool_class;
static struct device *mem_tool_device;
static const char devicename[] = "kernel_rw";

unsigned long util_find_kallsyms(void)
{
    int ret;

    if (kallsyms_lookup_name_fun_)
        return (unsigned long)kallsyms_lookup_name_fun_;

    ret = register_kprobe(&kp_kallsyms);
    if (ret < 0)
        return 0;

    kallsyms_lookup_name_fun_ = (void *)kp_kallsyms.addr;
    unregister_kprobe(&kp_kallsyms);
    return (unsigned long)kallsyms_lookup_name_fun_;
}

unsigned long util_kallsyms_lookup_name(const char *name)
{
    return kallsyms_lookup_name_fun_ ? kallsyms_lookup_name_fun_(name) : 0;
}

static uintptr_t find_module_base(pid_t pid, const char *name)
{
    struct task_struct *task;
    struct mm_struct *mm;
    struct vm_area_struct *vma;
    uintptr_t result = 0;

    rcu_read_lock();
    task = pid_task(find_vpid(pid), PIDTYPE_PID);
    rcu_read_unlock();
    if (!task)
        return 0;

    mm = get_task_mm(task);
    if (!mm)
        return 0;

    vma = find_vma(mm, 0);
    while (vma) {
        if (vma->vm_file) {
            char path_buffer[256] = { 0 };
            char *path = d_path(&vma->vm_file->f_path,
                                path_buffer, sizeof(path_buffer) - 1);
            if (!IS_ERR(path)) {
                char *base_name = strrchr(path, '/');
                base_name = base_name ? base_name + 1 : path;
                if (!strcmp(base_name, name)) {
                    result = vma->vm_start;
                    break;
                }
            }
        }

        if (vma->vm_end == ULONG_MAX)
            break;
        vma = find_vma(mm, vma->vm_end);
    }

    mmput(mm);
    return result;
}

long dispatch_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
    COPY_MEMORY cm = { 0 };
    MODULE_BASE mb = { 0 };
    HW_BP_INFO bp_info = { 0 };
    HWBP_HIT_ARGS hit_args = { 0 };
    char name[256] = { 0 };
    int ret;

    (void)file;

    switch (cmd) {
    case KERNEL_RW_IOCTL_INSTALL_HW_BP:
        if (copy_from_user(&bp_info, (void __user *)arg, sizeof(bp_info)))
            return -EFAULT;
        return install_hw_bp(&bp_info);

    case KERNEL_RW_IOCTL_GET_HW_BP_HITS:
        if (copy_from_user(&hit_args, (void __user *)arg, sizeof(hit_args)))
            return -EFAULT;
        ret = get_hw_bp_hits(&hit_args);
        if (ret)
            return ret;
        if (copy_to_user((void __user *)arg, &hit_args, sizeof(hit_args)))
            return -EFAULT;
        return 0;

    case KERNEL_RW_IOCTL_ENABLE_HW_BP:
        if (copy_from_user(&bp_info, (void __user *)arg, sizeof(bp_info)))
            return -EFAULT;
        return enable_hw_bp(&bp_info);

    case KERNEL_RW_IOCTL_CLEAR_ALL_HW_BPS:
        clear_all_hw_bps();
        return 0;

    case KERNEL_RW_IOCTL_DISABLE_HW_BP:
        if (copy_from_user(&bp_info, (void __user *)arg, sizeof(bp_info)))
            return -EFAULT;
        return disable_hw_bp(bp_info.pid, bp_info.addr);

    case KERNEL_RW_IOCTL_SET_TRACKING_DATA:
        if (copy_from_user(&g_tracking_data,
                           (void __user *)arg, sizeof(g_tracking_data))) {
            memset(&g_tracking_data, 0, sizeof(g_tracking_data));
            return -EFAULT;
        }
        return 0;

    case KERNEL_RW_IOCTL_READ_MEMORY:
        if (copy_from_user(&cm, (void __user *)arg, sizeof(cm)))
            return -EFAULT;
        return read_process_memory(cm.pid, cm.addr,
                                   (uintptr_t)cm.buffer, cm.size) ? 0 : -1;

    case KERNEL_RW_IOCTL_WRITE_MEMORY:
        if (copy_from_user(&cm, (void __user *)arg, sizeof(cm)))
            return -EFAULT;
        return write_process_memory(cm.pid, cm.addr,
                                    (uintptr_t)cm.buffer, cm.size) ? 0 : -1;

    case KERNEL_RW_IOCTL_MODULE_BASE:
        if (copy_from_user(&mb, (void __user *)arg, sizeof(mb)))
            return -EFAULT;
        if (copy_from_user(name, mb.name, sizeof(name) - 1))
            return -EFAULT;
        name[sizeof(name) - 1] = '\0';
        mb.base = find_module_base(mb.pid, name);
        if (copy_to_user((void __user *)arg, &mb, sizeof(mb)))
            return -EFAULT;
        return 0;

    default:
        return -EINVAL;
    }
}

int dispatch_open(struct inode *node, struct file *file)
{
    (void)node;
    file->private_data = &memdev;
    return 0;
}

int dispatch_close(struct inode *node, struct file *file)
{
    (void)node;
    (void)file;
    return 0;
}

static const struct file_operations dispatch_functions = {
    .owner          = THIS_MODULE,
    .open           = dispatch_open,
    .release        = dispatch_close,
    .unlocked_ioctl = dispatch_ioctl,
#ifdef CONFIG_COMPAT
    .compat_ioctl   = dispatch_ioctl,
#endif
};

static int __init kernel_rw_module_init(void)
{
    int ret;

    util_find_kallsyms();

    ret = alloc_chrdev_region(&mem_tool_dev_t, 0, 1, devicename);
    if (ret < 0)
        return ret;

    cdev_init(&memdev, &dispatch_functions);
    memdev.owner = THIS_MODULE;
    ret = cdev_add(&memdev, mem_tool_dev_t, 1);
    if (ret) {
        unregister_chrdev_region(mem_tool_dev_t, 1);
        return ret;
    }

    mem_tool_class = class_create(THIS_MODULE, devicename);
    if (IS_ERR(mem_tool_class)) {
        ret = PTR_ERR(mem_tool_class);
        cdev_del(&memdev);
        unregister_chrdev_region(mem_tool_dev_t, 1);
        return ret;
    }

    mem_tool_device = device_create(mem_tool_class, NULL, mem_tool_dev_t,
                                    NULL, "%s", devicename);
    if (IS_ERR(mem_tool_device)) {
        class_destroy(mem_tool_class);
        cdev_del(&memdev);
        unregister_chrdev_region(mem_tool_dev_t, 1);
        return 0; /* Preserve the existing device-create failure behavior. */
    }

    return 0;
}

static void __exit kernel_rw_module_exit(void)
{
    device_destroy(mem_tool_class, mem_tool_dev_t);
    class_destroy(mem_tool_class);
    cdev_del(&memdev);
    unregister_chrdev_region(mem_tool_dev_t, 1);
}

module_init(kernel_rw_module_init);
module_exit(kernel_rw_module_exit);
MODULE_LICENSE("GPL");
MODULE_IMPORT_NS(VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver);
