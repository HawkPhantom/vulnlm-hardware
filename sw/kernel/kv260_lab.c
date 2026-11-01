// SPDX-License-Identifier: GPL-2.0
/* Private-buffer lab. Recovery resets only compute, drains the existing DMA
 * packets, synchronizes callbacks, then releases reset. AXI/DDR is never reset
 * underneath pending transactions. E2 late-arms an idle receiver for stale A. */
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/of.h>
#include <linux/miscdevice.h>
#include <linux/fs.h>
#include <linux/uaccess.h>
#include <linux/dmaengine.h>
#include <linux/dma-mapping.h>
#include <linux/completion.h>
#include <linux/mutex.h>
#include <linux/kref.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/delay.h>
#include <linux/ktime.h>
#include <linux/compat.h>
#include <linux/capability.h>
#include <linux/version.h>
#include "kv260_uapi.h"
#include "kv260_contract.h"

#define GUARD 64U
#define GUARD_BYTE 0x6d
#define B_BYTE 0xa5
static bool allow_lab;
module_param(allow_lab, bool, 0400);
MODULE_PARM_DESC(allow_lab, "Enable private-buffer E1 experiments and frame capture");
static unsigned int recovery_grace_ms = 2000;
module_param(recovery_grace_ms, uint, 0400);
MODULE_PARM_DESC(recovery_grace_ms, "Extra E1/E2 observation time before abort/drain reset (1..60000 ms)");

struct kv_done {
    struct completion event;
    u64 ns;
    enum dmaengine_tx_result result;
    u32 residue;
};
struct kv_dev {
    struct kref refs;
    struct mutex lock;
    struct miscdevice misc;
    struct device *dev, *tx_dev, *rx_dev;
    void __iomem *regs;
    struct dma_chan *tx, *rx;
    void *input, *output;
    dma_addr_t input_dma, output_dma;
    struct kv_info info;
    atomic_t state;
    bool removing;
};

static void kv_free(struct kref *ref)
{
    kfree(container_of(ref, struct kv_dev, refs));
}

static void kv_complete(void *param, const struct dmaengine_result *result)
{
    struct kv_done *done = param;
    done->ns = ktime_get_ns();
    done->result = result ? result->result : DMA_TRANS_NOERROR;
    done->residue = result ? result->residue : 0;
    complete(&done->event);
}

static u64 kv_read64(struct kv_dev *d, unsigned reg)
{
    /* LAST fields are stable: caller serializes jobs and has observed LAST_SEQ. */
    return readl(d->regs + reg) | ((u64)readl(d->regs + reg + 4) << 32);
}

static int kv_submit(struct dma_chan *chan, dma_addr_t address, size_t len,
                     enum dma_transfer_direction direction, struct kv_done *done,
                     dma_cookie_t *cookie)
{
    struct dma_async_tx_descriptor *desc;
    init_completion(&done->event);
    done->ns = 0; done->result = DMA_TRANS_ABORTED; done->residue = 0;
    desc = dmaengine_prep_slave_single(chan, address, len, direction,
                                      DMA_PREP_INTERRUPT | DMA_CTRL_ACK);
    if (!desc)
        return -EIO;
    desc->callback_result = kv_complete;
    desc->callback_param = done;
    *cookie = dmaengine_submit(desc);
    return dma_submit_error(*cookie);
}

static u32 kv_guards(struct kv_dev *d)
{
    u8 *p = d->output;
    unsigned i;
    u32 errors = 0;
    for (i = 0; i < GUARD; i++) {
        errors += p[i] != GUARD_BYTE;
        errors += p[GUARD + d->info.output_bytes + i] != GUARD_BYTE;
    }
    return errors;
}

static void kv_e1_input(struct kv_dev *d)
{
    unsigned r;
    u8 *p = d->input;
    memset(p, (u8)-3, d->info.cols);
    for (r = 0; r < d->info.rows; r++)
        memset(p + d->info.cols * (r + 1), 1 + r % 64, d->info.cols);
}

static int kv_execute(struct kv_dev *d, struct kv_run *run)
{
    struct kv_done tx_done, rx_done;
    dma_cookie_t tx_cookie, rx_cookie;
    u32 seq, terminal, status, r, i;
    u8 *bytes = d->output + GUARD;
    __le32 *words = (void *)bytes;
    u64 deadline, recovery_deadline;
    bool expired = false, handed = false, recovering = false;
    bool rx_armed = run->op != KV_OP_E2;
    int ret;

    status = readl(d->regs + KV_REG_STATUS);
    if ((status & 7) != 2 || atomic_read(&d->state) == KV_STATE_BROKEN)
        return -EIO;
    if (run->op == KV_OP_E1)
        kv_e1_input(d);
    else if (copy_from_user(d->input, u64_to_user_ptr(run->input_ptr), d->info.input_bytes))
        return -EFAULT;
    memset(d->output, GUARD_BYTE, d->info.output_bytes + 2 * GUARD);
    memset(bytes, B_BYTE, d->info.output_bytes);
    seq = readl(d->regs + KV_REG_LAST_SEQ);
    /* AXI DMA may accept beats even before S2MM is armed. Hold the source
     * upstream of the DMA until the intended receive descriptor is issued. */
    writel(run->op == KV_OP_E2, d->regs + KV_REG_RECEIVE_HOLD);
    readl(d->regs + KV_REG_RECEIVE_HOLD);
    run->recovery_count = readl(d->regs + KV_REG_RECOVERY_COUNT);
    writel(0, d->regs + KV_REG_IRQ_ENABLE); /* Poll terminal records; DMA has IRQs. */
    writel(3, d->regs + KV_REG_IRQ_STATUS);
    writel(run->job_id, d->regs + KV_REG_JOB);
    writel(run->generation, d->regs + KV_REG_GENERATION);
    writel(run->delay_cycles, d->regs + KV_REG_DELAY);
    dma_wmb();
    /* Prepare+submit each descriptor as a pair. Neither channel is issued yet. */
    init_completion(&rx_done.event);
    rx_done.ns = 0; rx_done.result = DMA_TRANS_ABORTED; rx_done.residue = 0;
    if (rx_armed) {
        ret = kv_submit(d->rx, d->output_dma + GUARD, d->info.output_bytes,
                    DMA_DEV_TO_MEM, &rx_done, &rx_cookie);
        if (ret)
            return ret;
    }
    ret = kv_submit(d->tx, d->input_dma, d->info.input_bytes,
                    DMA_MEM_TO_DEV, &tx_done, &tx_cookie);
    if (ret) {
        /* RX has never been issued: no memory or stream activity to drain. */
        if (rx_armed && dmaengine_terminate_sync(d->rx)) {
            atomic_set(&d->state, KV_STATE_BROKEN);
            /* Keep the callback storage alive if termination cannot be proven. */
            wait_for_completion(&rx_done.event);
            dmaengine_synchronize(d->rx);
        }
        return ret;
    }
    atomic_set(&d->state, KV_STATE_RUNNING);
    run->submit_ns = ktime_get_ns();
    deadline = run->submit_ns + (u64)run->timeout_ms * NSEC_PER_MSEC;
    recovery_deadline = deadline + (run->op == KV_OP_RUN || run->op == KV_OP_RECOVERY_TEST ?
                                   0 : (u64)recovery_grace_ms * NSEC_PER_MSEC);
    if (rx_armed)
        dma_async_issue_pending(d->rx);
    writel(1, d->regs + KV_REG_CONTROL);
    /* Flush posted control before enabling input producer. */
    readl(d->regs + KV_REG_STATUS);
    dma_async_issue_pending(d->tx);

    while (!completion_done(&tx_done.event) || !completion_done(&rx_done.event)) {
        if (!expired && ktime_get_ns() >= deadline) {
            expired = true; run->timed_out = 1; run->timeout_ns = ktime_get_ns();
            atomic_set(&d->state, KV_STATE_QUARANTINED);
            dev_warn(d->dev, "job %u/%u timeout; retaining DMA buffers until drain\n",
                     run->job_id, run->generation);
            if (run->op == KV_OP_E1 || run->op == KV_OP_CAPTURE) {
                run->window_hit = !completion_done(&rx_done.event);
                if (run->policy < 2 && run->window_hit) {
                    /* Intentional private synthetic scratch-buffer race. */
                    run->handoff_ns = ktime_get_ns(); handed = true;
                    memset(bytes, B_BYTE, d->info.output_bytes);
                    dma_wmb();
                }
            }
        }
        if (run->op == KV_OP_E2 && !rx_armed && expired && !recovering &&
            completion_done(&tx_done.event) &&
            (readl(d->regs + KV_REG_STREAM_STATE) & 1) &&
            readl(d->regs + KV_REG_STREAM_OUTPUT) == 0) {
            /* No A RX descriptor was issued, hence no RX memory transaction
             * exists to cancel. Source A remains held VALID throughout rearm.
             * This is receiver rearm, not a reset of an active DMA master. */
            dmaengine_synchronize(d->tx);
            ret = dmaengine_terminate_sync(d->rx);
            if (!ret) {
                ret = kv_submit(d->rx, d->output_dma + GUARD, d->info.output_bytes,
                                DMA_DEV_TO_MEM, &rx_done, &rx_cookie);
            }
            if (ret) {
                atomic_set(&d->state, KV_STATE_BROKEN);
                return ret; /* TX is synchronized; RX was never issued. */
            }
            run->window_hit = 1;
            run->old_completion_rejected = run->policy != 0;
            if (run->policy < 2) {
                run->handoff_ns = ktime_get_ns(); handed = true;
                memset(bytes, B_BYTE, d->info.output_bytes); dma_wmb();
            }
            rx_armed = true;
            dma_async_issue_pending(d->rx);
            writel(0, d->regs + KV_REG_RECEIVE_HOLD);
            readl(d->regs + KV_REG_RECEIVE_HOLD);
            /* Give the newly armed receiver its observation interval. */
            recovery_deadline = ktime_get_ns() + (u64)recovery_grace_ms * NSEC_PER_MSEC;
        }
        if (!recovering && ktime_get_ns() >= recovery_deadline) {
            if (!rx_armed) {
                ret = kv_submit(d->rx, d->output_dma + GUARD, d->info.output_bytes,
                                DMA_DEV_TO_MEM, &rx_done, &rx_cookie);
                if (ret) {
                    /* MM2S can still own input/callback storage: retain both
                     * until it finishes, then leave the device broken. */
                    atomic_set(&d->state, KV_STATE_BROKEN);
                    wait_for_completion(&tx_done.event);
                    dmaengine_synchronize(d->tx);
                    return ret;
                }
                rx_armed = true; dma_async_issue_pending(d->rx);
            }
            recovering = true;
            writel(1, d->regs + KV_REG_RECOVERY);
            readl(d->regs + KV_REG_RECOVERY_STATUS);
        }
        /* The supervisor drains stream packets. A nonresponding DDR/fabric
         * still retains memory: stream reset cannot prove AXI completion. */
        msleep(1);
    }
    dmaengine_synchronize(d->tx);
    dmaengine_synchronize(d->rx);
    run->tx_done_ns = tx_done.ns; run->rx_done_ns = rx_done.ns;
    if (!expired && max(tx_done.ns, rx_done.ns) > deadline) {
        expired = true; run->timed_out = 1; run->timeout_ns = ktime_get_ns();
        /* Completion was already observed: no early-handoff window to test. */
    }
    dma_rmb();
    if (recovering) {
        u32 recovery_status, count = run->recovery_count;
        run->guard_errors = kv_guards(d);
        ret = readl_poll_timeout(d->regs + KV_REG_RECOVERY_STATUS, recovery_status,
                                 recovery_status == 3, 10, 100000);
        if (ret || run->guard_errors || tx_done.result != DMA_TRANS_NOERROR ||
            rx_done.result != DMA_TRANS_NOERROR || tx_done.residue || rx_done.residue ||
            dma_async_is_tx_complete(d->tx, tx_cookie, NULL, NULL) != DMA_COMPLETE ||
            dma_async_is_tx_complete(d->rx, rx_cookie, NULL, NULL) != DMA_COMPLETE) {
            atomic_set(&d->state, KV_STATE_BROKEN);
            run->status = -EIO; run->release_ns = ktime_get_ns(); return 0;
        }
        /* Both DMA callbacks have drained and synchronized. Only now may the
         * compute reset be released and a new job own these buffers. */
        writel(2, d->regs + KV_REG_RECOVERY);
        ret = readl_poll_timeout(d->regs + KV_REG_RECOVERY_COUNT, terminal,
                                 terminal == count + 1, 10, 100000);
        status = readl(d->regs + KV_REG_STATUS);
        run->recovery_count = terminal;
        run->release_ns = ktime_get_ns();
        if (ret || readl(d->regs + KV_REG_RECOVERY_STATUS) || (status & 7) != 2) {
            atomic_set(&d->state, KV_STATE_BROKEN); run->status = -EIO;
        } else {
            atomic_set(&d->state, KV_STATE_IDLE);
            run->recovery_flags = KV_RECOVERY_DRAINED_RESET;
            run->window_hit = 0; run->status = -ETIMEDOUT;
        }
        return 0; /* Never expose padding/discarded data as a product result. */
    }
    ret = readl_poll_timeout(d->regs + KV_REG_LAST_SEQ, terminal,
                            terminal != seq, 10, 100000);
    status = readl(d->regs + KV_REG_STATUS);
    if (ret || !kv_can_reuse(1, 1, (status & 7) == 2, 1,
        readl(d->regs + KV_REG_LAST_JOB) == run->job_id &&
        readl(d->regs + KV_REG_LAST_GENERATION) == run->generation) ||
        tx_done.result != DMA_TRANS_NOERROR || rx_done.result != DMA_TRANS_NOERROR ||
        tx_done.residue || rx_done.residue ||
        dma_async_is_tx_complete(d->tx, tx_cookie, NULL, NULL) != DMA_COMPLETE ||
        dma_async_is_tx_complete(d->rx, rx_cookie, NULL, NULL) != DMA_COMPLETE ||
        readl(d->regs + KV_REG_LAST_OUTCOME) != 1 ||
        readl(d->regs + KV_REG_LAST_ERROR) ||
        readl(d->regs + KV_REG_LAST_INPUT) != d->info.input_bytes / 4 ||
        readl(d->regs + KV_REG_LAST_OUTPUT) != d->info.output_bytes / 4) {
        atomic_set(&d->state, KV_STATE_BROKEN);
        run->status = -EIO;
        return 0;
    }
    run->core_cycles = kv_read64(d, KV_REG_LAST_CYCLES);
    run->stall_cycles = kv_read64(d, KV_REG_LAST_STALL);
    run->guard_errors = kv_guards(d);
    if (run->op == KV_OP_E1 && run->timed_out && run->window_hit) {
        if (handed) {
            for (i = 0; i < d->info.output_bytes; i++)
                run->changed_bytes += bytes[i] != B_BYTE;
            for (r = 0; r < d->info.rows; r++) {
                s32 a = -3 * (s32)d->info.cols * (1 + r % 64);
                s32 b = 2 * (s32)d->info.cols * (3 + r % 5);
                s32 value = le32_to_cpu(words[r]);
                run->late_a_words += value == a;
                if (run->policy == 0 && value != b)
                    run->mock_bad_response = 1;
            }
        }
        run->old_completion_rejected = run->policy != 0;
        if (run->policy == 2) {
            run->handoff_ns = ktime_get_ns();
            memset(bytes, B_BYTE, d->info.output_bytes);
        }
    }
    if ((run->op == KV_OP_CAPTURE || run->op == KV_OP_E2) &&
        run->timed_out && run->window_hit && run->policy == 2)
        run->handoff_ns = ktime_get_ns();
    if ((run->op == KV_OP_CAPTURE || run->op == KV_OP_E2) && handed)
        for (i = 0; i < d->info.output_bytes; i++)
            run->changed_bytes += bytes[i] != B_BYTE;
    run->release_ns = ktime_get_ns();
    run->status = run->guard_errors ? -EIO : expired ? -ETIMEDOUT : 0;
    atomic_set(&d->state, run->guard_errors ? KV_STATE_BROKEN : KV_STATE_IDLE);
    /* Capture exposes only this caller's A-tagged diagnostic snapshot after
     * successful drain. Product association/rejection is the service's job.
     * Normal RUN still never returns late data as a successful result. */
    if (((!run->status && run->op == KV_OP_RUN) ||
         ((run->op == KV_OP_CAPTURE || run->op == KV_OP_E2) &&
          (run->status == 0 || run->status == -ETIMEDOUT))) &&
        copy_to_user(u64_to_user_ptr(run->output_ptr), bytes, d->info.output_bytes))
        return -EFAULT;
    return 0;
}

static int kv_open(struct inode *inode, struct file *file)
{
    struct kv_dev *d = container_of(file->private_data, struct kv_dev, misc);
    kref_get(&d->refs);
    file->private_data = d;
    return nonseekable_open(inode, file);
}
static int kv_close(struct inode *inode, struct file *file)
{
    kref_put(&((struct kv_dev *)file->private_data)->refs, kv_free);
    return 0;
}
static long kv_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
    struct kv_dev *d = file->private_data;
    void __user *user = (void __user *)arg;
    struct kv_info info;
    struct kv_run run;
    int ret;
    if (cmd == KV_GET_INFO) {
        info = d->info; info.state = atomic_read(&d->state);
        return copy_to_user(user, &info, sizeof(info)) ? -EFAULT : 0;
    }
    if (cmd != KV_RUN)
        return -ENOTTY;
    if (copy_from_user(&run, user, sizeof(run)))
        return -EFAULT;
    if (run.abi != KV_ABI_VERSION || run.op > KV_OP_RECOVERY_TEST || run.policy > 2 ||
        run.reserved || run.timeout_ms < 1 || run.timeout_ms > 60000 ||
        (run.op == KV_OP_RUN && run.policy != 2) ||
        ((run.op != KV_OP_E1) &&
         (!run.input_ptr || !run.output_ptr || run.input_bytes != d->info.input_bytes ||
          run.output_bytes != d->info.output_bytes)))
        return -EINVAL;
    if (run.op != KV_OP_RUN && (!allow_lab || !capable(CAP_SYS_RAWIO)))
        return -EPERM;
    /* Ignore caller-supplied result fields. */
    memset_after(&run, 0, output_bytes);
    if (mutex_lock_interruptible(&d->lock))
        return -ERESTARTSYS;
    if (d->removing) ret = -ENODEV;
    else if (atomic_read(&d->state) == KV_STATE_BROKEN) ret = -EIO;
    else ret = kv_execute(d, &run);
    mutex_unlock(&d->lock);
    if (ret)
        return ret;
    return copy_to_user(user, &run, sizeof(run)) ? -EFAULT : 0;
}
#ifdef CONFIG_COMPAT
static long kv_compat_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
    return kv_ioctl(file, cmd, (unsigned long)compat_ptr(arg));
}
#endif
static const struct file_operations kv_fops = {
    .owner = THIS_MODULE, .open = kv_open, .release = kv_close,
    .unlocked_ioctl = kv_ioctl,
#ifdef CONFIG_COMPAT
    .compat_ioctl = kv_compat_ioctl,
#endif
};

static int kv_probe(struct platform_device *pdev)
{
    struct kv_dev *d;
    int ret;
    d = kzalloc(sizeof(*d), GFP_KERNEL);
    if (!d) return -ENOMEM;
    kref_init(&d->refs); mutex_init(&d->lock); d->dev = &pdev->dev;
    d->regs = devm_platform_ioremap_resource(pdev, 0);
    if (IS_ERR(d->regs)) { ret = PTR_ERR(d->regs); goto free_d; }
    if (readl(d->regs + KV_REG_ID) != KV_DEVICE_ID ||
        readl(d->regs + KV_REG_VERSION) != KV_DEVICE_VERSION) { ret = -ENODEV; goto free_d; }
    d->info.abi = KV_ABI_VERSION;
    d->info.rows = readl(d->regs + KV_REG_ROWS);
    d->info.cols = readl(d->regs + KV_REG_COLS);
    d->info.input_bytes = readl(d->regs + KV_REG_INPUT_BYTES);
    d->info.output_bytes = readl(d->regs + KV_REG_OUTPUT_BYTES);
    d->info.lab_enabled = allow_lab;
    d->info.capabilities = KV_CAP_CAPTURE | KV_CAP_RECOVERY | KV_CAP_E2;
    if (!kv_valid_shape(d->info.rows, d->info.cols) ||
        d->info.input_bytes != (d->info.rows + 1) * d->info.cols ||
        d->info.output_bytes != d->info.rows * 4 ||
        d->info.input_bytes > KV_MAX_INPUT || d->info.output_bytes > KV_MAX_OUTPUT) {
        ret = -EINVAL; goto free_d;
    }
    /* Bind only at boot/after a clean FPGA load: no unknown prior DMA owner. */
    if (!recovery_grace_ms || recovery_grace_ms > 60000 ||
        readl(d->regs + KV_REG_FEATURES) != 3 ||
        (readl(d->regs + KV_REG_STATUS) & 7) != 2 ||
        readl(d->regs + KV_REG_LAST_SEQ) != 0) { ret = -EBUSY; goto free_d; }
    d->tx = dma_request_chan(&pdev->dev, "tx");
    if (IS_ERR(d->tx)) { ret = PTR_ERR(d->tx); goto free_d; }
    d->rx = dma_request_chan(&pdev->dev, "rx");
    if (IS_ERR(d->rx)) { ret = PTR_ERR(d->rx); goto release_tx; }
    d->tx_dev = dmaengine_get_dma_device(d->tx);
    d->rx_dev = dmaengine_get_dma_device(d->rx);
    d->input = dma_alloc_coherent(d->tx_dev, d->info.input_bytes, &d->input_dma, GFP_KERNEL);
    if (!d->input) { ret = -ENOMEM; goto release_rx; }
    d->output = dma_alloc_coherent(d->rx_dev, d->info.output_bytes + 2 * GUARD,
                                  &d->output_dma, GFP_KERNEL);
    if (!d->output) { ret = -ENOMEM; goto free_input; }
    d->misc.minor = MISC_DYNAMIC_MINOR; d->misc.name = "kv260-lab";
    d->misc.fops = &kv_fops; d->misc.parent = &pdev->dev; d->misc.mode = 0600;
    atomic_set(&d->state, KV_STATE_IDLE);
    platform_set_drvdata(pdev, d);
    ret = misc_register(&d->misc);
    if (ret) goto free_output;
    dev_info(&pdev->dev, "INT8 %ux%u, private buffers, P2 drain service ready\n",
             d->info.rows, d->info.cols);
    return 0;
free_output:
    dma_free_coherent(d->rx_dev, d->info.output_bytes + 2 * GUARD, d->output, d->output_dma);
free_input:
    dma_free_coherent(d->tx_dev, d->info.input_bytes, d->input, d->input_dma);
release_rx: dma_release_channel(d->rx);
release_tx: dma_release_channel(d->tx);
free_d: kref_put(&d->refs, kv_free); return ret;
}

#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 11, 0)
static int kv_remove(struct platform_device *pdev)
#else
static void kv_remove(struct platform_device *pdev)
#endif
{
    struct kv_dev *d = platform_get_drvdata(pdev);
    misc_deregister(&d->misc);
    /* Active ioctl holds this lock until both DMA paths/callbacks drain.
     * A permanent fault can block removal; memory is never freed early. */
    mutex_lock(&d->lock); d->removing = true;
    dma_free_coherent(d->rx_dev, d->info.output_bytes + 2 * GUARD, d->output, d->output_dma);
    dma_free_coherent(d->tx_dev, d->info.input_bytes, d->input, d->input_dma);
    dma_release_channel(d->rx); dma_release_channel(d->tx);
    mutex_unlock(&d->lock);
    kref_put(&d->refs, kv_free);
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 11, 0)
    return 0;
#endif
}
static const struct of_device_id kv_of_match[] = {
    { .compatible = "hardware-secx,kv260-matvec-1.0" }, { }
};
MODULE_DEVICE_TABLE(of, kv_of_match);
static struct platform_driver kv_driver = {
    .probe = kv_probe, .remove = kv_remove,
    .driver = { .name = "kv260-lab", .of_match_table = kv_of_match,
                .suppress_bind_attrs = true },
};
module_platform_driver(kv_driver);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("KV260 INT8 DMA lifecycle research service");
