/* Copyright (c) 2026 Yurii Rashkovskii
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */

#include <signal.h>

extern int flyology_bench_worker_signal_terminate(void);
extern int flyology_bench_worker_signal_kill(void);
extern int flyology_bench_worker_errno_interrupted(void);
extern int flyology_bench_worker_errno_would_block(void);
extern int flyology_bench_worker_errno_no_process(void);
extern int flyology_bench_worker_errno_permission(void);

int main(void)
{
    if (flyology_bench_worker_signal_terminate() != SIGTERM) return 1;
    if (flyology_bench_worker_signal_kill() != SIGKILL) return 2;
    if (flyology_bench_worker_errno_interrupted() <= 0) return 3;
    if (flyology_bench_worker_errno_would_block() <= 0) return 4;
    if (flyology_bench_worker_errno_no_process() <= 0) return 5;
    if (flyology_bench_worker_errno_permission() <= 0) return 6;
    return 0;
}
