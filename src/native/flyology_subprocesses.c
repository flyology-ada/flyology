#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

/*
 * Subprocess ABI leaves only.
 *
 * posix_spawn file-action and attribute objects, waitid's siginfo_t payload,
 * signal-number macros, wait-status macros, pipe2 flags, and SIGPIPE masking
 * are C-only or host-header-selected interfaces. This file exposes those
 * mechanisms through fixed signatures. Ada owns validation, argv/environment
 * construction, retry and deadline policy, descriptor ownership and cleanup,
 * signal selection, reaping order, bounded capture, and lifecycle decisions.
 */

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stddef.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

_Static_assert(sizeof(pid_t) <= sizeof(int), "pid_t must fit the Ada ABI");
_Static_assert(sizeof(ssize_t) <= sizeof(long), "ssize_t must fit the Ada ABI");

static int flyology_move_above_stdio(int *descriptor)
{
    int replacement;

    if (*descriptor > STDERR_FILENO) return 0;
#if defined(F_DUPFD_CLOEXEC)
    replacement = fcntl(*descriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1);
#else
    replacement = fcntl(*descriptor, F_DUPFD, STDERR_FILENO + 1);
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

static int flyology_spawn_addchdir(posix_spawn_file_actions_t *actions,
                                   const char *working_directory)
{
#if defined(__APPLE__)
#if defined(__ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__) && \
    __ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__ >= 260000
    return posix_spawn_file_actions_addchdir(actions, working_directory);
#else
    /*
     * The replacement spelling exists only on macOS 26.  Retain the older
     * symbol when the deployment target permits earlier systems, while
     * containing the current SDK's deprecation diagnostic at this ABI leaf.
     */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    int result = posix_spawn_file_actions_addchdir_np(actions,
                                                       working_directory);
#pragma clang diagnostic pop
    return result;
#endif
#elif defined(__GLIBC_PREREQ) && __GLIBC_PREREQ(2, 29)
    return posix_spawn_file_actions_addchdir_np(actions, working_directory);
#else
    (void)actions;
    (void)working_directory;
    return ENOTSUP;
#endif
}

int flyology_subprocess_pipe(int descriptors[2])
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
    if (flyology_move_above_stdio(&descriptors[0]) < 0 ||
        flyology_move_above_stdio(&descriptors[1]) < 0) {
        int saved = errno;
        (void)close(descriptors[0]);
        (void)close(descriptors[1]);
        errno = saved;
        return -1;
    }
    return 0;
}

int flyology_subprocess_set_nonblocking(int descriptor)
{
    int flags = fcntl(descriptor, F_GETFL);
    if (flags < 0) return -1;
    return fcntl(descriptor, F_SETFL, flags | O_NONBLOCK);
}

int flyology_subprocess_spawn(pid_t *pid,
                              const char *executable,
                              char *const argv[],
                              int explicit_environment,
                              char *const environment[],
                              const char *working_directory,
                              int search_path,
                              int stdin_read,
                              int stdin_write,
                              int stdout_read,
                              int stdout_write,
                              int stderr_read,
                              int stderr_write)
{
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    sigset_t empty_mask;
    sigset_t defaults;
    short flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK |
                  POSIX_SPAWN_SETSIGDEF;
    int result;

    result = posix_spawn_file_actions_init(&actions);
    if (result != 0) return result;
    result = posix_spawnattr_init(&attributes);
    if (result != 0) {
        (void)posix_spawn_file_actions_destroy(&actions);
        return result;
    }

#define FLYOLOGY_ACTION(call) do { result = (call); if (result != 0) goto done; } while (0)
    FLYOLOGY_ACTION(posix_spawn_file_actions_adddup2(&actions, stdin_read,
                                                     STDIN_FILENO));
    FLYOLOGY_ACTION(posix_spawn_file_actions_adddup2(&actions, stdout_write,
                                                     STDOUT_FILENO));
    FLYOLOGY_ACTION(posix_spawn_file_actions_adddup2(&actions, stderr_write,
                                                     STDERR_FILENO));
    FLYOLOGY_ACTION(posix_spawn_file_actions_addclose(&actions, stdin_read));
    FLYOLOGY_ACTION(posix_spawn_file_actions_addclose(&actions, stdin_write));
    FLYOLOGY_ACTION(posix_spawn_file_actions_addclose(&actions, stdout_read));
    FLYOLOGY_ACTION(posix_spawn_file_actions_addclose(&actions, stdout_write));
    FLYOLOGY_ACTION(posix_spawn_file_actions_addclose(&actions, stderr_read));
    FLYOLOGY_ACTION(posix_spawn_file_actions_addclose(&actions, stderr_write));

    if (working_directory != NULL) {
        FLYOLOGY_ACTION(flyology_spawn_addchdir(&actions,
                                                working_directory));
    }

    (void)sigemptyset(&empty_mask);
    (void)sigfillset(&defaults);
    (void)sigdelset(&defaults, SIGKILL);
    (void)sigdelset(&defaults, SIGSTOP);
    FLYOLOGY_ACTION(posix_spawnattr_setsigmask(&attributes, &empty_mask));
    FLYOLOGY_ACTION(posix_spawnattr_setsigdefault(&attributes, &defaults));
    FLYOLOGY_ACTION(posix_spawnattr_setpgroup(&attributes, 0));
    FLYOLOGY_ACTION(posix_spawnattr_setflags(&attributes, flags));

    if (search_path) {
        result = posix_spawnp(pid, executable, &actions, &attributes, argv,
                              explicit_environment ? environment : environ);
    } else {
        result = posix_spawn(pid, executable, &actions, &attributes, argv,
                             explicit_environment ? environment : environ);
    }

done:
    (void)posix_spawnattr_destroy(&attributes);
    (void)posix_spawn_file_actions_destroy(&actions);
    return result;
#undef FLYOLOGY_ACTION
}

int flyology_subprocess_observe_exit(pid_t pid)
{
    siginfo_t information;
    if (waitid(P_PID, (id_t)pid, &information, WEXITED | WNOWAIT) == 0)
        return 0;
    return errno;
}

long flyology_subprocess_write_no_sigpipe(int descriptor,
                                          const void *buffer,
                                          size_t length)
{
    sigset_t blocked;
    sigset_t previous;
    sigset_t pending;
    int caught;
    int was_pending = 0;
    ssize_t result;
    int saved;

    (void)sigemptyset(&blocked);
    (void)sigaddset(&blocked, SIGPIPE);
    if (pthread_sigmask(SIG_BLOCK, &blocked, &previous) != 0) {
        errno = EINVAL;
        return -1;
    }
    if (sigpending(&pending) == 0) was_pending = sigismember(&pending, SIGPIPE);
    result = write(descriptor, buffer, length);
    saved = errno;
    if (result < 0 && saved == EPIPE && !was_pending)
        (void)sigwait(&blocked, &caught);
    (void)pthread_sigmask(SIG_SETMASK, &previous, NULL);
    errno = saved;
    return (long)result;
}

int flyology_subprocess_signal_interrupt(void) { return SIGINT; }
int flyology_subprocess_signal_terminate(void) { return SIGTERM; }
int flyology_subprocess_signal_kill(void) { return SIGKILL; }
int flyology_subprocess_errno_interrupted(void) { return EINTR; }
int flyology_subprocess_errno_would_block(void) { return EAGAIN; }
int flyology_subprocess_errno_no_such_process(void) { return ESRCH; }
int flyology_subprocess_errno_permission(void) { return EPERM; }

int flyology_subprocess_status_exited(int status) { return WIFEXITED(status); }
int flyology_subprocess_status_exit_code(int status) { return WEXITSTATUS(status); }
int flyology_subprocess_status_signaled(int status) { return WIFSIGNALED(status); }
int flyology_subprocess_status_signal(int status) { return WTERMSIG(status); }
int flyology_subprocess_status_core_dumped(int status)
{
#if defined(WCOREDUMP)
    return WCOREDUMP(status) != 0;
#else
    (void)status;
    return 0;
#endif
}
