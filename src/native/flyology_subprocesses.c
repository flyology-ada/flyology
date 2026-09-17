#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

/*
 * Subprocess ABI leaves only.
 *
 * posix_spawn file-action and attribute objects, waitid's siginfo_t payload,
 * signal-number and errno macros, wait-status macros, pipe2 flags, variadic fcntl
 * duplication, bootstrap file actions, SIGPIPE configuration, and SIGPIPE
 * masking are C-only or host-header-selected interfaces. This file exposes those
 * mechanisms through fixed signatures. A detached pthread also owns the
 * waitid-to-waitpid sequence after its Ada owner can disappear. Ada retains
 * launch and lifecycle decisions, validation, argv/environment construction,
 * public signal selection, retry and deadline policy, error classification,
 * and bounded capture. No detached worker calls Ada or GNARL.
 */

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stddef.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

_Static_assert(sizeof(pid_t) <= sizeof(int), "pid_t must fit the Ada ABI");
_Static_assert(sizeof(ssize_t) <= sizeof(long), "ssize_t must fit the Ada ABI");

static int flyology_move_above(int *descriptor, int reserved_maximum)
{
    int replacement;

    if (*descriptor > reserved_maximum) return 0;
#if defined(F_DUPFD_CLOEXEC)
    replacement = fcntl(*descriptor, F_DUPFD_CLOEXEC, reserved_maximum + 1);
#else
    replacement = fcntl(*descriptor, F_DUPFD, reserved_maximum + 1);
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
    if (flyology_move_above(&descriptors[0], STDERR_FILENO) < 0 ||
        flyology_move_above(&descriptors[1], STDERR_FILENO) < 0) {
        int saved = errno;
        (void)close(descriptors[0]);
        (void)close(descriptors[1]);
        errno = saved;
        return -1;
    }
    return 0;
}

int flyology_subprocess_duplicate_above(int descriptor, int minimum)
{
#if defined(F_DUPFD_CLOEXEC)
    return fcntl(descriptor, F_DUPFD_CLOEXEC, minimum);
#else
    int replacement = fcntl(descriptor, F_DUPFD, minimum);
    if (replacement < 0) return -1;
    if (fcntl(replacement, F_SETFD, FD_CLOEXEC) < 0) {
        int saved = errno;
        (void)close(replacement);
        errno = saved;
        return -1;
    }
    return replacement;
#endif
}

int flyology_subprocess_set_nonblocking(int descriptor)
{
    int flags = fcntl(descriptor, F_GETFL);
    if (flags < 0) return -1;
    return fcntl(descriptor, F_SETFL, flags | O_NONBLOCK);
}

int flyology_subprocess_set_no_sigpipe(int descriptor)
{
#if defined(__APPLE__)
    return fcntl(descriptor, F_SETNOSIGPIPE, 1);
#else
    (void)descriptor;
    return 0;
#endif
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
                              int stderr_write,
                              int control_parent,
                              int control_child,
                              int capability_parent,
                              int capability_child,
                              int control_target,
                              int capability_target)
{
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    sigset_t empty_mask;
    sigset_t defaults;
    short flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK |
                  POSIX_SPAWN_SETSIGDEF;
    int result;
    /* Ada validates the all-disabled or four-distinct-descriptor contract. */
    int bootstrap = control_parent != -1;

#if defined(__APPLE__)
    flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif

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
#if defined(__APPLE__)
    FLYOLOGY_ACTION(posix_spawn_file_actions_addinherit_np(&actions,
                                                           STDIN_FILENO));
#endif
    if (stdout_write >= 0) {
        FLYOLOGY_ACTION(posix_spawn_file_actions_adddup2
          (&actions, stdout_write, STDOUT_FILENO));
    }
#if defined(__APPLE__)
    FLYOLOGY_ACTION(posix_spawn_file_actions_addinherit_np(&actions,
                                                           STDOUT_FILENO));
#endif
    if (stderr_write >= 0) {
        FLYOLOGY_ACTION(posix_spawn_file_actions_adddup2
          (&actions, stderr_write, STDERR_FILENO));
    }
#if defined(__APPLE__)
    FLYOLOGY_ACTION(posix_spawn_file_actions_addinherit_np(&actions,
                                                           STDERR_FILENO));
#endif
    FLYOLOGY_ACTION(posix_spawn_file_actions_addclose(&actions, stdin_read));
    FLYOLOGY_ACTION(posix_spawn_file_actions_addclose(&actions, stdin_write));
    if (stdout_read >= 0) {
        FLYOLOGY_ACTION(posix_spawn_file_actions_addclose
          (&actions, stdout_read));
        FLYOLOGY_ACTION(posix_spawn_file_actions_addclose
          (&actions, stdout_write));
    }
    if (stderr_read >= 0) {
        FLYOLOGY_ACTION(posix_spawn_file_actions_addclose
          (&actions, stderr_read));
        FLYOLOGY_ACTION(posix_spawn_file_actions_addclose
          (&actions, stderr_write));
    }

    if (bootstrap) {
        FLYOLOGY_ACTION(posix_spawn_file_actions_adddup2
          (&actions, control_child, control_target));
        FLYOLOGY_ACTION(posix_spawn_file_actions_adddup2
          (&actions, capability_child, capability_target));
#if defined(__APPLE__)
        FLYOLOGY_ACTION(posix_spawn_file_actions_addinherit_np
          (&actions, control_target));
        FLYOLOGY_ACTION(posix_spawn_file_actions_addinherit_np
          (&actions, capability_target));
#endif
        FLYOLOGY_ACTION(posix_spawn_file_actions_addclose
          (&actions, control_parent));
        FLYOLOGY_ACTION(posix_spawn_file_actions_addclose
          (&actions, control_child));
        FLYOLOGY_ACTION(posix_spawn_file_actions_addclose
          (&actions, capability_parent));
        FLYOLOGY_ACTION(posix_spawn_file_actions_addclose
          (&actions, capability_child));
    }

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

/*
 * A detached worker is required for a reaper that may outlive Ada's library
 * task master. Its state contains no Ada object or callback. The waitid to
 * waitpid interval and signal mutex are one native mechanism: after the Ada
 * owner disappears, Ada cannot safely execute the group cleanup or reap.
 * Launch, deadlines, cancellation, retries of public calls, and error
 * classification remain in Ada.
 */
struct flyology_subprocess_reaper {
    pthread_mutex_t mutex;
    pid_t pid;
    int read_fd;
    int write_fd;
    int references;
    int owner_alive;
    int observed;
    int done;
    int status;
    int error;
};

#if FLYOLOGY_SUBPROCESS_TEST_HOOKS
static pthread_mutex_t reaper_barrier_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t reaper_barrier_condition = PTHREAD_COND_INITIALIZER;
static int reaper_barrier_armed;
static int reaper_barrier_reached;
static int reaper_barrier_released;

void flyology_test_subprocess_arm_reap_barrier(void)
{
    (void)pthread_mutex_lock(&reaper_barrier_mutex);
    reaper_barrier_armed = 1;
    reaper_barrier_reached = 0;
    reaper_barrier_released = 0;
    (void)pthread_mutex_unlock(&reaper_barrier_mutex);
}

void flyology_test_subprocess_await_reap_barrier(void)
{
    (void)pthread_mutex_lock(&reaper_barrier_mutex);
    while (!reaper_barrier_reached)
        (void)pthread_cond_wait(&reaper_barrier_condition, &reaper_barrier_mutex);
    (void)pthread_mutex_unlock(&reaper_barrier_mutex);
}

void flyology_test_subprocess_release_reap_barrier(void)
{
    (void)pthread_mutex_lock(&reaper_barrier_mutex);
    reaper_barrier_released = 1;
    (void)pthread_cond_broadcast(&reaper_barrier_condition);
    (void)pthread_mutex_unlock(&reaper_barrier_mutex);
}

static void flyology_reaper_test_after_reap(void)
{
    (void)pthread_mutex_lock(&reaper_barrier_mutex);
    if (reaper_barrier_armed) {
        reaper_barrier_reached = 1;
        (void)pthread_cond_broadcast(&reaper_barrier_condition);
        while (!reaper_barrier_released)
            (void)pthread_cond_wait(&reaper_barrier_condition, &reaper_barrier_mutex);
        reaper_barrier_armed = 0;
    }
    (void)pthread_mutex_unlock(&reaper_barrier_mutex);
}
#endif

static void flyology_reaper_drop_worker(struct flyology_subprocess_reaper *state)
{
    int destroy;
    (void)pthread_mutex_lock(&state->mutex);
    destroy = --state->references == 0;
    (void)pthread_mutex_unlock(&state->mutex);
    if (destroy) {
        (void)pthread_mutex_destroy(&state->mutex);
        free(state);
    }
}

static void *flyology_reaper_worker(void *argument)
{
    struct flyology_subprocess_reaper *state = argument;
    sigset_t synchronous;
    int error;
    int group_error = 0;
    int status = 0;
    pid_t result;

    (void)sigemptyset(&synchronous);
    (void)sigaddset(&synchronous, SIGBUS);
    (void)sigaddset(&synchronous, SIGFPE);
    (void)sigaddset(&synchronous, SIGILL);
    (void)sigaddset(&synchronous, SIGSEGV);
    /* The creator only adds asynchronous blocks. If it already blocked a
       synchronous fault, unblock that signal on the worker before waiting. */
    if (pthread_sigmask(SIG_UNBLOCK, &synchronous, NULL) != 0) abort();

    do {
        error = flyology_subprocess_observe_exit(state->pid);
    } while (error == EINTR);

    /* WNOWAIT retains the PID/PGID until waitpid. Exclude public signals
       before releasing that reservation, including the publication gap. */
    (void)pthread_mutex_lock(&state->mutex);
    state->observed = 1;
    (void)pthread_mutex_unlock(&state->mutex);

    if (error == 0) {
        if (kill(-state->pid, SIGKILL) != 0 &&
            errno != ESRCH && errno != EPERM)
            group_error = errno;
        /* A group-cleanup error still leaves the observed root waitable.
           Reap it before reporting the original failure to the owner. */
        do {
            result = waitpid(state->pid, &status, 0);
        } while (result < 0 && errno == EINTR);
        if (result != state->pid) error = errno;
        if (group_error != 0) error = group_error;
    }
#if FLYOLOGY_SUBPROCESS_TEST_HOOKS
    flyology_reaper_test_after_reap();
#endif
    (void)pthread_mutex_lock(&state->mutex);
    state->status = status;
    state->error = error;
    state->done = 1;
    if (state->owner_alive && state->write_fd >= 0) {
        char byte = 1;
        (void)write(state->write_fd, &byte, 1);
    }
    if (state->write_fd >= 0) {
        (void)close(state->write_fd);
        state->write_fd = -1;
    }
    (void)pthread_mutex_unlock(&state->mutex);
    flyology_reaper_drop_worker(state);
    return NULL;
}

int flyology_subprocess_reaper_start(int pid, void **result)
{
    struct flyology_subprocess_reaper *state;
    pthread_attr_t attributes;
    pthread_t thread;
    sigset_t blocked, previous;
    int descriptors[2] = {-1, -1};
    int error;

    *result = NULL;
    state = calloc(1, sizeof(*state));
    if (state == NULL) return ENOMEM;
    error = pthread_mutex_init(&state->mutex, NULL);
    if (error != 0) { free(state); return error; }
    if (flyology_subprocess_pipe(descriptors) != 0) {
        error = errno;
        (void)pthread_mutex_destroy(&state->mutex);
        free(state);
        return error;
    }
    if (flyology_subprocess_set_nonblocking(descriptors[0]) != 0 ||
        flyology_subprocess_set_nonblocking(descriptors[1]) != 0) {
        error = errno;
        if (descriptors[0] >= 0) (void)close(descriptors[0]);
        if (descriptors[1] >= 0) (void)close(descriptors[1]);
        (void)pthread_mutex_destroy(&state->mutex);
        free(state);
        return error;
    }
    state->pid = (pid_t)pid;
    state->read_fd = descriptors[0];
    state->write_fd = descriptors[1];
    state->references = 2;
    state->owner_alive = 1;
    error = pthread_attr_init(&attributes);
    if (error == 0) {
        error = pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
        if (error == 0) {
            (void)sigfillset(&blocked);
            (void)sigdelset(&blocked, SIGBUS);
            (void)sigdelset(&blocked, SIGFPE);
            (void)sigdelset(&blocked, SIGILL);
            (void)sigdelset(&blocked, SIGSEGV);
            error = pthread_sigmask(SIG_BLOCK, &blocked, &previous);
            if (error == 0) {
                int restore_error;
                error = pthread_create(&thread, &attributes, flyology_reaper_worker, state);
                restore_error = pthread_sigmask(SIG_SETMASK, &previous, NULL);
                /* A failed restore leaves the caller's signal state unknown.
                   The worker may already own state, so it cannot be freed. */
                if (restore_error != 0) abort();
            }
        }
        (void)pthread_attr_destroy(&attributes);
    }
    if (error != 0) {
        (void)close(state->read_fd);
        (void)close(state->write_fd);
        (void)pthread_mutex_destroy(&state->mutex);
        free(state);
        return error;
    }
    *result = state;
    return 0;
}

void flyology_subprocess_reaper_snapshot(void *pointer, int *done, int *failed,
                                         int *status, int *error)
{
    struct flyology_subprocess_reaper *state = pointer;
    (void)pthread_mutex_lock(&state->mutex);
    *done = state->done;
    *failed = state->error != 0;
    *status = state->status;
    *error = state->error;
    (void)pthread_mutex_unlock(&state->mutex);
}

int flyology_subprocess_reaper_descriptor(void *pointer)
{
    struct flyology_subprocess_reaper *state = pointer;
    return state->read_fd;
}

int flyology_subprocess_reaper_signal(void *pointer, int signal_number,
                                      int forced_error, int *attempted)
{
    struct flyology_subprocess_reaper *state = pointer;
    int error = 0;
    *attempted = 0;
    (void)pthread_mutex_lock(&state->mutex);
    if (!state->observed && !state->done) {
        if (forced_error != 0) error = forced_error;
        else {
            *attempted = 1;
            if (kill(-state->pid, signal_number) != 0) error = errno;
        }
    }
    (void)pthread_mutex_unlock(&state->mutex);
    return error;
}

void flyology_subprocess_reaper_release(void *pointer)
{
    struct flyology_subprocess_reaper *state = pointer;
    int destroy;
    (void)pthread_mutex_lock(&state->mutex);
    state->owner_alive = 0;
    (void)close(state->read_fd);
    state->read_fd = -1;
    if (state->write_fd >= 0) {
        (void)close(state->write_fd);
        state->write_fd = -1;
    }
    destroy = --state->references == 0;
    (void)pthread_mutex_unlock(&state->mutex);
    if (destroy) {
        (void)pthread_mutex_destroy(&state->mutex);
        free(state);
    }
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
    /* An ignored SIGPIPE is discarded rather than made pending. */
    if (result < 0 && saved == EPIPE && !was_pending &&
        sigpending(&pending) == 0 && sigismember(&pending, SIGPIPE))
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
int flyology_subprocess_errno_broken_pipe(void) { return EPIPE; }
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
