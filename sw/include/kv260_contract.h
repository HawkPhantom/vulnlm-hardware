/* SPDX-License-Identifier: GPL-2.0 */
#ifndef KV260_CONTRACT_H
#define KV260_CONTRACT_H
#define KV_REG_ID 0x000
#define KV_REG_VERSION 0x004
#define KV_REG_CONTROL 0x008
#define KV_REG_STATUS 0x00c
#define KV_REG_JOB 0x010
#define KV_REG_GENERATION 0x014
#define KV_REG_DELAY 0x018
#define KV_REG_IRQ_ENABLE 0x01c
#define KV_REG_IRQ_STATUS 0x020
#define KV_REG_ROWS 0x030
#define KV_REG_COLS 0x034
#define KV_REG_INPUT_BYTES 0x038
#define KV_REG_OUTPUT_BYTES 0x03c
#define KV_REG_LAST_SEQ 0x06c
#define KV_REG_LAST_JOB 0x070
#define KV_REG_LAST_GENERATION 0x074
#define KV_REG_LAST_ERROR 0x078
#define KV_REG_LAST_INPUT 0x07c
#define KV_REG_LAST_OUTPUT 0x080
#define KV_REG_LAST_CYCLES 0x084
#define KV_REG_LAST_STALL 0x08c
#define KV_REG_LAST_OUTCOME 0x094
#define KV_DEVICE_ID 0x4d565831U
#define KV_DEVICE_VERSION 0x00010001U
#define KV_REG_RECOVERY 0x098
#define KV_REG_RECOVERY_STATUS 0x09c
#define KV_REG_RECOVERY_COUNT 0x0a0
#define KV_REG_FEATURES 0x0a4
#define KV_REG_STREAM_STATE 0x0a8
#define KV_REG_STREAM_OUTPUT 0x0ac
#define KV_REG_RECEIVE_HOLD 0x0b0

/* One in-flight job, no stream FIFOs in this board design. Reuse requires all
 * three completions plus synchronized callbacks, matching terminal identity.
 * No reset/abort path may weaken these conditions. */
static inline int kv_can_reuse(int tx_done, int rx_done, int source_clean,
                               int callbacks_synced, int identity_ok)
{
    return tx_done && rx_done && source_clean && callbacks_synced && identity_ok;
}
static inline int kv_valid_shape(unsigned rows, unsigned cols)
{
    return rows >= 1 && rows <= 4096 && cols >= 4 && cols <= 4096 && cols % 4 == 0;
}
#endif
