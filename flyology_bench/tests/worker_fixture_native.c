/* Copyright (c) 2026 Yurii Rashkovskii
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/types.h>
#include <unistd.h>

void flyology_bench_worker_test_abort(void)
{
    (void)signal(SIGABRT, SIG_DFL);
    (void)raise(SIGABRT);
    _exit(127);
}

int flyology_bench_worker_test_ignore_terminate(void)
{
    struct sigaction action;
    action.sa_handler = SIG_IGN;
    (void)sigemptyset(&action.sa_mask);
    action.sa_flags = 0;
    return sigaction(SIGTERM, &action, NULL);
}

int flyology_bench_worker_test_descriptor_open(int descriptor)
{
    int result = fcntl(descriptor, F_GETFD);
    return result >= 0 ? 1 : (errno == EBADF ? 0 : -1);
}

int flyology_bench_worker_test_pid_exists(int pid)
{
    if (kill((pid_t)pid, 0) == 0 || errno == EPERM) return 1;
    return errno == ESRCH ? 0 : -1;
}

int flyology_bench_worker_test_spawn_stubborn_descendant(void)
{
    pid_t child = fork();
    if (child != 0) return (int)child;

    /* Ada tasking is initialized in the worker.  The fork child therefore
     * uses only async-signal-safe operations until _exit. */
    (void)signal(SIGTERM, SIG_IGN);
    for (;;) (void)pause();
    _exit(127);
}

static struct sigaction saved_sigchld;
static int saved_sigchld_valid = 0;

int flyology_bench_worker_test_ignore_sigchld(void)
{
    struct sigaction action;
    if (saved_sigchld_valid) {
        errno = EBUSY;
        return -1;
    }
    action.sa_handler = SIG_IGN;
    (void)sigemptyset(&action.sa_mask);
    action.sa_flags = 0;
    if (sigaction(SIGCHLD, &action, &saved_sigchld) != 0) return -1;
    saved_sigchld_valid = 1;
    return 0;
}

int flyology_bench_worker_test_restore_sigchld(void)
{
    int result;
    if (!saved_sigchld_valid) {
        errno = EINVAL;
        return -1;
    }
    result = sigaction(SIGCHLD, &saved_sigchld, NULL);
    if (result == 0) saved_sigchld_valid = 0;
    return result;
}
