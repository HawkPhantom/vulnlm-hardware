/* SPDX-License-Identifier: GPL-2.0 */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include "kv260_uapi.h"
#include "kv260_contract.h"

_Static_assert(sizeof(struct kv_info) == 32, "info ABI layout");
_Static_assert(sizeof(struct kv_run) == 160, "run ABI layout");
static uint32_t rng_state = 20261030U;
static uint32_t next_random(void)
{
    rng_state ^= rng_state << 13; rng_state ^= rng_state >> 17; rng_state ^= rng_state << 5;
    return rng_state;
}
static unsigned number(const char *text)
{
    char *end;
    unsigned long value;
    errno = 0; value = strtoul(text, &end, 0);
    if (errno || !*text || *end || text[0] == '-' || value > UINT32_MAX) {
        fprintf(stderr, "Invalid unsigned number: %s\n", text); exit(2);
    }
    return (unsigned)value;
}
static int32_t reference(const int8_t *frame, unsigned row, unsigned cols)
{
    int64_t result = 0;
    for (unsigned c = 0; c < cols; c++)
        result += (int32_t)frame[c] * frame[(row + 1) * cols + c];
    return (int32_t)result;
}
static int32_t read_le32(const unsigned char *p)
{
    uint32_t value = (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
    int32_t result;
    memcpy(&result, &value, sizeof(result));
    return result;
}
static void print_run(const struct kv_run *r)
{
    printf("{\"kind\":\"%s\",\"policy\":%u,\"job_id\":%u,\"generation\":%u,"
           "\"delay_cycles\":%u,\"timeout_ms\":%u,\"status\":%d,\"timed_out\":%u,"
           "\"window_hit\":%u,\"changed_bytes\":%u,\"late_a_words\":%u,"
           "\"mock_bad_response\":%u,\"old_completion_rejected\":%u,\"guard_errors\":%u,"
           "\"submit_ns\":%" PRIu64 ",\"timeout_ns\":%" PRIu64 ",\"handoff_ns\":%" PRIu64 ","
           "\"tx_done_ns\":%" PRIu64 ",\"rx_done_ns\":%" PRIu64 ",\"release_ns\":%" PRIu64 ","
           "\"core_cycles\":%" PRIu64 ",\"stall_cycles\":%" PRIu64 "}\n",
           r->op == KV_OP_E1 ? "hardware_E1_private_scratch" : "hardware_run",
           r->policy, r->job_id, r->generation, r->delay_cycles, r->timeout_ms,
           r->status, r->timed_out, r->window_hit, r->changed_bytes, r->late_a_words,
           r->mock_bad_response, r->old_completion_rejected, r->guard_errors,
           (uint64_t)r->submit_ns, (uint64_t)r->timeout_ns, (uint64_t)r->handoff_ns,
           (uint64_t)r->tx_done_ns, (uint64_t)r->rx_done_ns, (uint64_t)r->release_ns,
           (uint64_t)r->core_cycles, (uint64_t)r->stall_cycles);
    fflush(stdout);
}
static int selftest(void)
{
    /* CPU-only self-test is explicitly distinct from an ioctl/hardware run. */
    for (unsigned mask = 0; mask < 32; mask++)
        if (!!kv_can_reuse(mask & 1, mask & 2, mask & 4, mask & 8, mask & 16) != (mask == 31))
            return 1;
    if (!kv_valid_shape(64, 64) || kv_valid_shape(0, 4) || kv_valid_shape(2, 7)) return 1;
    const int8_t frame[] = {-128,127,-1,1, -128,127,127,-128};
    const unsigned char minus[] = {0x00,0xff,0xff,0xff};
    if (reference(frame, 0, 4) != 32258 || read_le32(minus) != -256) return 1;
    puts("PASS host contract, signed reference, endian and ABI (no hardware)");
    return 0;
}
int main(int argc, char **argv)
{
    const char *device = getenv("KV260_DEVICE");
    struct kv_info info = {0};
    int fd, result = 0;
    if (argc == 2 && !strcmp(argv[1], "selftest")) return selftest();
    if (argc < 2 || (strcmp(argv[1], "info") && strcmp(argv[1], "verify") && strcmp(argv[1], "e1"))) {
        fprintf(stderr, "Usage: kv260ctl selftest | info | verify [count=100 seed=20261030 timeout_ms=1000] | e1 policy delay_cycles timeout_ms [count=1]\n");
        return 2;
    }
    fd = open(device ? device : "/dev/kv260-lab", O_RDWR | O_CLOEXEC);
    if (fd < 0) { perror("open kv260-lab"); return 1; }
    if (ioctl(fd, KV_GET_INFO, &info) < 0) { perror("KV_GET_INFO"); close(fd); return 1; }
    if (info.abi != KV_ABI_VERSION || !kv_valid_shape(info.rows, info.cols) ||
        info.input_bytes != (info.rows + 1) * info.cols || info.output_bytes != info.rows * 4 ||
        info.input_bytes > KV_MAX_INPUT || info.output_bytes > KV_MAX_OUTPUT) {
        fprintf(stderr, "Incompatible device shape/ABI\n"); close(fd); return 1;
    }
    if (!strcmp(argv[1], "info")) {
        printf("{\"abi\":%u,\"rows\":%u,\"cols\":%u,\"input_bytes\":%u,\"output_bytes\":%u,\"state\":%u,\"lab_enabled\":%u,\"capabilities\":%u}\n",
               info.abi, info.rows, info.cols, info.input_bytes, info.output_bytes, info.state, info.lab_enabled, info.capabilities);
    } else if (!strcmp(argv[1], "verify")) {
        unsigned count = argc > 2 ? number(argv[2]) : 100;
        unsigned seed = argc > 3 ? number(argv[3]) : 20261030;
        unsigned timeout = argc > 4 ? number(argv[4]) : 1000;
        int8_t *input = malloc(info.input_bytes);
        unsigned char *output = malloc(info.output_bytes);
        if (!input || !output || !count || !seed || !timeout || timeout > 60000) {
            fprintf(stderr, "Invalid arguments or allocation failure\n"); free(input); free(output); close(fd); return 2;
        }
        rng_state = seed;
        for (unsigned job = 0; job < count; job++) {
            struct kv_run run = {.abi=KV_ABI_VERSION, .op=KV_OP_RUN, .policy=2,
                .job_id=job+1, .generation=1, .timeout_ms=timeout,
                .input_ptr=(uintptr_t)input, .output_ptr=(uintptr_t)output,
                .input_bytes=info.input_bytes, .output_bytes=info.output_bytes};
            for (unsigned i = 0; i < info.input_bytes; i++) {
                unsigned char byte = (unsigned char)next_random();
                memcpy(&input[i], &byte, 1);
            }
            memset(output, 0xa5, info.output_bytes);
            if (ioctl(fd, KV_RUN, &run) < 0) { perror("KV_RUN"); result=1; break; }
            print_run(&run);
            if (run.status) { fprintf(stderr, "Job status %d; no valid output\n", run.status); result=1; break; }
            for (unsigned row = 0; row < info.rows; row++)
                if (read_le32(output+4*row) != reference(input, row, info.cols)) {
                    fprintf(stderr, "Reference mismatch job=%u row=%u\n", job+1, row); result=1; break;
                }
            if (result) break;
        }
        fprintf(stderr, result ? "FAIL hardware verification\n" : "PASS hardware verification\n");
        free(input); free(output);
    } else {
        if (argc < 5 || argc > 6) { fprintf(stderr, "e1 needs policy, delay and timeout\n"); close(fd); return 2; }
        unsigned policy=number(argv[2]), delay=number(argv[3]), timeout=number(argv[4]);
        unsigned count=argc > 5 ? number(argv[5]) : 1;
        if (policy > 2 || !delay || !timeout || timeout > 60000 || !count) { close(fd); return 2; }
        for (unsigned job=0; job<count; job++) {
            struct kv_run run = {.abi=KV_ABI_VERSION, .op=KV_OP_E1, .policy=policy,
                .job_id=0xa001+job, .generation=1, .delay_cycles=delay, .timeout_ms=timeout};
            if (ioctl(fd, KV_RUN, &run) < 0) { perror("KV_RUN E1"); result=1; break; }
            print_run(&run);
            if (run.guard_errors || (run.status && run.status != -ETIMEDOUT)) { result=1; break; }
            if (!run.window_hit) { fprintf(stderr, "E1 window missed; retain record and adjust pilot delay\n"); result=3; }
        }
    }
    close(fd); return result;
}
