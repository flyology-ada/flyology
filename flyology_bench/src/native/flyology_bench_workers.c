/* Copyright (c) 2026 Yurii Rashkovskii
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

/* Fresh-process worker ABI leaves.
 *
 * posix_spawn action/attribute objects, closefrom actions, waitid siginfo,
 * wait-status macros, and signal constants have no stable Ada representation.
 * This file exposes only fixed-signature mechanisms selected by host headers.
 * Ada owns executable/environment validation, argv construction, deadline and
 * retry policy, protocol parsing, capture bounds, signal sequencing, reaping,
 * outcome classification, and every cleanup decision.
 *
 * A fork fallback is intentionally absent.  Flyology_Bench is standalone and
 * may be called after Ada tasking has started; a child must reach exec without
 * running Ada code or inherited-runtime cleanup.
 */

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stddef.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

_Static_assert(sizeof(pid_t) == sizeof(int), "pid_t must match the Ada ABI");
_Static_assert(sizeof(ssize_t) == sizeof(long), "ssize_t must match the Ada ABI");

enum { RESULT_DESCRIPTOR = 3, FIRST_CLOSED_DESCRIPTOR = 4 };

static int move_above_result(int *descriptor)
{
    int replacement;

    if (*descriptor >= FIRST_CLOSED_DESCRIPTOR) return 0;
#if defined(F_DUPFD_CLOEXEC)
    replacement = fcntl(*descriptor, F_DUPFD_CLOEXEC,
                        FIRST_CLOSED_DESCRIPTOR);
#else
    replacement = fcntl(*descriptor, F_DUPFD, FIRST_CLOSED_DESCRIPTOR);
#endif
    if (replacement < 0) return -1;
#if !defined(F_DUPFD_CLOEXEC)
    if (fcntl(replacement, F_SETFD, FD_CLOEXEC) < 0) {
        int saved = errno;
        (void)close(replacement);
        errno = saved;
        return -1;
    }
#endif
    (void)close(*descriptor);
    *descriptor = replacement;
    return 0;
}

static int make_pipe(int descriptors[2])
{
#if defined(__linux__)
    if (pipe2(descriptors, O_CLOEXEC) < 0) return -1;
#else
    if (pipe(descriptors) < 0) return -1;
    if (fcntl(descriptors[0], F_SETFD, FD_CLOEXEC) < 0 ||
        fcntl(descriptors[1], F_SETFD, FD_CLOEXEC) < 0) {
        int saved = errno;
        (void)close(descriptors[0]);
        (void)close(descriptors[1]);
        errno = saved;
        return -1;
    }
#endif
    if (move_above_result(&descriptors[0]) < 0 ||
        move_above_result(&descriptors[1]) < 0) {
        int saved = errno;
        (void)close(descriptors[0]);
        (void)close(descriptors[1]);
        errno = saved;
        return -1;
    }
    return 0;
}

int flyology_bench_worker_set_nonblocking(int descriptor)
{
    int flags = fcntl(descriptor, F_GETFL);
    if (flags < 0) return -1;
    return fcntl(descriptor, F_SETFL, flags | O_NONBLOCK);
}

static int add_chdir(posix_spawn_file_actions_t *actions,
                     const char *directory)
{
#if defined(__APPLE__)
#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#elif defined(__GNUC__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
#endif
    int result = posix_spawn_file_actions_addchdir_np(actions, directory);
#if defined(__clang__)
#pragma clang diagnostic pop
#elif defined(__GNUC__)
#pragma GCC diagnostic pop
#endif
    return result;
#elif defined(__GLIBC_PREREQ) && __GLIBC_PREREQ(2, 29)
    return posix_spawn_file_actions_addchdir_np(actions, directory);
#else
    (void)actions;
    (void)directory;
    return ENOTSUP;
#endif
}

static int add_closefrom(posix_spawn_file_actions_t *actions)
{
#if defined(__APPLE__)
#if defined(POSIX_SPAWN_CLOEXEC_DEFAULT)
    (void)actions;
    return 0;
#else
    (void)actions;
    return ENOTSUP;
#endif
#elif defined(__GLIBC_PREREQ) && __GLIBC_PREREQ(2, 34)
    return posix_spawn_file_actions_addclosefrom_np(
        actions, FIRST_CLOSED_DESCRIPTOR);
#else
    (void)actions;
    return ENOTSUP;
#endif
}

static void close_pair(int pair[2])
{
    if (pair[0] >= 0) (void)close(pair[0]);
    if (pair[1] >= 0) (void)close(pair[1]);
    pair[0] = -1;
    pair[1] = -1;
}

int flyology_bench_worker_spawn(int *pid,
                                int parent_descriptors[3],
                                const char *executable,
                                char *const arguments[],
                                char *const environment[],
                                const char *working_directory)
{
    int result_pipe[2] = {-1, -1};
    int output_pipe[2] = {-1, -1};
    int error_pipe[2] = {-1, -1};
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    sigset_t empty_mask;
    sigset_t defaults;
    short flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK |
                  POSIX_SPAWN_SETSIGDEF;
    int actions_ready = 0;
    int attributes_ready = 0;
    int result;

    parent_descriptors[0] = -1;
    parent_descriptors[1] = -1;
    parent_descriptors[2] = -1;
    if (make_pipe(result_pipe) < 0 || make_pipe(output_pipe) < 0 ||
        make_pipe(error_pipe) < 0) {
        result = errno;
        goto done;
    }
    result = posix_spawn_file_actions_init(&actions);
    if (result != 0) goto done;
    actions_ready = 1;
    result = posix_spawnattr_init(&attributes);
    if (result != 0) goto done;
    attributes_ready = 1;

#define ACTION(call) do { result = (call); if (result != 0) goto done; } while (0)
    ACTION(posix_spawn_file_actions_addopen(
        &actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0));
    ACTION(posix_spawn_file_actions_adddup2(
        &actions, output_pipe[1], STDOUT_FILENO));
    ACTION(posix_spawn_file_actions_adddup2(
        &actions, error_pipe[1], STDERR_FILENO));
    ACTION(posix_spawn_file_actions_adddup2(
        &actions, result_pipe[1], RESULT_DESCRIPTOR));
    ACTION(add_closefrom(&actions));
    if (working_directory != NULL) ACTION(add_chdir(&actions, working_directory));

    (void)sigemptyset(&empty_mask);
    (void)sigfillset(&defaults);
    (void)sigdelset(&defaults, SIGKILL);
    (void)sigdelset(&defaults, SIGSTOP);
    ACTION(posix_spawnattr_setsigmask(&attributes, &empty_mask));
    ACTION(posix_spawnattr_setsigdefault(&attributes, &defaults));
    ACTION(posix_spawnattr_setpgroup(&attributes, 0));
#if defined(__APPLE__) && defined(POSIX_SPAWN_CLOEXEC_DEFAULT)
    flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
    ACTION(posix_spawnattr_setflags(&attributes, flags));
    result = posix_spawn((pid_t *)pid, executable, &actions, &attributes,
                         arguments, environment);
#undef ACTION

done:
    if (attributes_ready) (void)posix_spawnattr_destroy(&attributes);
    if (actions_ready) (void)posix_spawn_file_actions_destroy(&actions);
    if (result == 0) {
        (void)close(result_pipe[1]); result_pipe[1] = -1;
        (void)close(output_pipe[1]); output_pipe[1] = -1;
        (void)close(error_pipe[1]); error_pipe[1] = -1;
        parent_descriptors[0] = result_pipe[0]; result_pipe[0] = -1;
        parent_descriptors[1] = output_pipe[0]; output_pipe[0] = -1;
        parent_descriptors[2] = error_pipe[0]; error_pipe[0] = -1;
    }
    close_pair(result_pipe);
    close_pair(output_pipe);
    close_pair(error_pipe);
    return result;
}

/* 0 means running, 1 means exited but deliberately unreaped, -1 means error.
 * Retaining the zombie prevents PID/process-group reuse until Ada finishes all
 * group signaling and performs the one final waitpid.
 */
int flyology_bench_worker_observe_exit(int pid)
{
    siginfo_t information;
    (void)memset(&information, 0, sizeof(information));
    if (waitid(P_PID, (id_t)pid, &information,
               WEXITED | WNOHANG | WNOWAIT) != 0)
        return -1;
    return information.si_pid == 0 ? 0 : 1;
}

int flyology_bench_worker_signal_terminate(void) { return SIGTERM; }
int flyology_bench_worker_signal_kill(void) { return SIGKILL; }
int flyology_bench_worker_errno_interrupted(void) { return EINTR; }
int flyology_bench_worker_errno_would_block(void) { return EAGAIN; }
int flyology_bench_worker_errno_no_process(void) { return ESRCH; }
int flyology_bench_worker_errno_permission(void) { return EPERM; }
int flyology_bench_worker_status_exited(int status) { return WIFEXITED(status); }
int flyology_bench_worker_status_exit_code(int status)
{
    return WEXITSTATUS(status);
}
int flyology_bench_worker_status_signaled(int status)
{
    return WIFSIGNALED(status);
}
int flyology_bench_worker_status_signal(int status)
{
    return WTERMSIG(status);
}

/* Focused fixture/ABI observations.  These contain no worker policy. */
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
