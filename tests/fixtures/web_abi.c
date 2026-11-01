#include <stddef.h>
#include <stdio.h>
#include "kv260_uapi.h"
int main(void)
{
    printf("{\"info_size\":%zu,\"run_size\":%zu,\"input_offset\":%zu,\"status_offset\":%zu,"
           "\"submit_offset\":%zu,\"get_info\":%lu,\"run\":%lu,\"capture_op\":%u,\"capture_cap\":%u,"
           "\"recovery_offset\":%zu,\"e2_op\":%u,\"recovery_op\":%u,\"e2_cap\":%u,\"recovery_cap\":%u}\n",
           sizeof(struct kv_info), sizeof(struct kv_run), offsetof(struct kv_run,input_ptr),
           offsetof(struct kv_run,status), offsetof(struct kv_run,submit_ns),
           (unsigned long)KV_GET_INFO,(unsigned long)KV_RUN,KV_OP_CAPTURE,KV_CAP_CAPTURE,
           offsetof(struct kv_run,recovery_flags),KV_OP_E2,KV_OP_RECOVERY_TEST,KV_CAP_E2,KV_CAP_RECOVERY);
    return 0;
}
