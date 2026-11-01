/* SPDX-License-Identifier: GPL-2.0 WITH Linux-syscall-note */
#ifndef KV260_UAPI_H
#define KV260_UAPI_H
#ifdef __linux__
#include <linux/types.h>
#include <linux/ioctl.h>
#else
#include <stdint.h>
#include <sys/ioctl.h>
typedef uint32_t __u32;
typedef uint64_t __u64;
typedef int32_t __s32;
#endif

#define KV_ABI_VERSION 1U
#define KV_MAX_INPUT (1024U * 1024U)
#define KV_MAX_OUTPUT (4096U * 4U)
#define KV_MAGIC 'K'
#define KV_OP_RUN 0U
#define KV_OP_E1 1U
/* Arbitrary-frame E1 capture for the real-device product demonstrator.
 * output_ptr receives an A-tagged diagnostic DMA snapshot after drain,
 * including after timeout. It is never implicitly a valid B response. */
#define KV_OP_CAPTURE 2U
#define KV_CAP_CAPTURE (1U << 0)
#define KV_STATE_IDLE 0U
#define KV_STATE_RUNNING 1U
#define KV_STATE_QUARANTINED 2U
#define KV_STATE_BROKEN 3U

struct kv_info {
    /* capabilities occupies the previously reserved, zero-initialized word. */
    __u32 abi, rows, cols, input_bytes, output_bytes, state, lab_enabled, capabilities;
};

/* Fixed-width pointers and explicit padding: same layout for compat ioctl.
 * ioctl returns transport errors as errno. A completed run's status is below.
 * No physical/DMA addresses are part of this ABI. Zero all reserved fields. */
struct kv_run {
    __u32 abi, op, policy, job_id;
    __u32 generation, delay_cycles, timeout_ms, reserved;
    __u64 input_ptr, output_ptr;
    __u32 input_bytes, output_bytes;
    __s32 status; /* 0, -ETIMEDOUT (drained, discarded), or terminal error */
    __u32 timed_out, window_hit, changed_bytes, late_a_words, mock_bad_response;
    __u32 old_completion_rejected, guard_errors, reserved_out[2];
    __u64 submit_ns, timeout_ns, handoff_ns, tx_done_ns, rx_done_ns, release_ns;
    __u64 core_cycles, stall_cycles;
};
#define KV_GET_INFO _IOR(KV_MAGIC, 0, struct kv_info)
#define KV_RUN _IOWR(KV_MAGIC, 1, struct kv_run)
#endif
