#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

/* Compare the fixed subprocess leaf ABI with the host C interfaces. */

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stddef.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

int flyology_subprocess_pipe(int[2]);
int flyology_subprocess_duplicate_above(int, int);
int flyology_subprocess_set_nonblocking(int);
int flyology_subprocess_set_no_sigpipe(int);
int flyology_subprocess_spawn(pid_t *, const char *, char *const [], int,
                              char *const [], const char *, int,
                              int, int, int, int, int, int,
                              int, int, int, int, int, int);
long flyology_subprocess_write_no_sigpipe(int, const void *, size_t);
int flyology_subprocess_signal_interrupt(void);
int flyology_subprocess_signal_terminate(void);
int flyology_subprocess_signal_kill(void);
int flyology_subprocess_errno_interrupted(void);
int flyology_subprocess_errno_would_block(void);
int flyology_subprocess_errno_broken_pipe(void);
int flyology_subprocess_errno_no_such_process(void);
int flyology_subprocess_errno_permission(void);
int flyology_subprocess_status_exited(int);
int flyology_subprocess_status_exit_code(int);
int flyology_subprocess_status_signaled(int);
int flyology_subprocess_status_signal(int);
int flyology_subprocess_status_core_dumped(int);

static int move_above_bootstrap(int *descriptor)
{
    int replacement;
    if (*descriptor > 4) return 0;
    replacement = flyology_subprocess_duplicate_above(*descriptor, 5);
    if (replacement < 0) return -1;
    close(*descriptor);
    *descriptor = replacement;
    return 0;
}

int main(int argc, char **argv)
{
    int descriptors[2] = { -1, -1 };
    int input[2] = { -1, -1 };
    int output[2] = { -1, -1 };
    int error[2] = { -1, -1 };
    int bootstrap_control[2] = { -1, -1 };
    int bootstrap_capability[2] = { -1, -1 };
    int status = 0;
    pid_t child;
    pid_t live_child = -1;
    char byte = 'x';
    int result = 1;
    int sigpipe_overridden = 0;
    struct sigaction ignored_pipe;
    struct sigaction observed_pipe;
    struct sigaction previous_pipe;

    if (argc == 2 && strcmp(argv[1], "--wait-for-signal") == 0) {
        for (;;) pause();
    }
    if (argc == 2 && strcmp(argv[1], "--bootstrap-child") == 0) {
        char control = 'C';
        char capability = 'K';
        if (fcntl(3, F_GETFD) < 0 || fcntl(4, F_GETFD) < 0 ||
            (fcntl(3, F_GETFD) & FD_CLOEXEC) != 0 ||
            (fcntl(4, F_GETFD) & FD_CLOEXEC) != 0 ||
            write(3, &control, 1) != 1 || write(4, &capability, 1) != 1)
            return 2;
        return 0;
    }

    if (flyology_subprocess_signal_interrupt() != SIGINT ||
        flyology_subprocess_signal_terminate() != SIGTERM ||
        flyology_subprocess_signal_kill() != SIGKILL ||
        flyology_subprocess_errno_interrupted() != EINTR ||
        flyology_subprocess_errno_would_block() != EAGAIN ||
        flyology_subprocess_errno_broken_pipe() != EPIPE ||
        flyology_subprocess_errno_no_such_process() != ESRCH ||
        flyology_subprocess_errno_permission() != EPERM)
        return 1;

    if (flyology_subprocess_pipe(descriptors) != 0 ||
        descriptors[0] <= STDERR_FILENO || descriptors[1] <= STDERR_FILENO ||
        (fcntl(descriptors[0], F_GETFD) & FD_CLOEXEC) == 0 ||
        (fcntl(descriptors[1], F_GETFD) & FD_CLOEXEC) == 0 ||
        (fcntl(descriptors[0], F_GETFL) & O_NONBLOCK) != 0 ||
        (fcntl(descriptors[1], F_GETFL) & O_NONBLOCK) != 0)
        goto cleanup;
    if (flyology_subprocess_set_nonblocking(descriptors[0]) != 0 ||
        (fcntl(descriptors[0], F_GETFL) & O_NONBLOCK) == 0)
        goto cleanup;
    if (flyology_subprocess_set_no_sigpipe(descriptors[1]) != 0)
        goto cleanup;
#if defined(__APPLE__)
    if (fcntl(descriptors[1], F_GETNOSIGPIPE) != 1)
        goto cleanup;
#endif

    close(descriptors[0]);
    descriptors[0] = -1;
    /* Match launchers that deliberately pass an ignored SIGPIPE to children. */
    memset(&ignored_pipe, 0, sizeof(ignored_pipe));
    ignored_pipe.sa_handler = SIG_IGN;
    sigemptyset(&ignored_pipe.sa_mask);
    if (sigaction(SIGPIPE, &ignored_pipe, &previous_pipe) != 0)
        goto cleanup;
    sigpipe_overridden = 1;
    errno = 0;
    if (flyology_subprocess_write_no_sigpipe
          (descriptors[1], &byte, sizeof(byte)) != -1 || errno != EPIPE)
        goto cleanup;
    if (sigaction(SIGPIPE, NULL, &observed_pipe) != 0 ||
        observed_pipe.sa_handler != SIG_IGN ||
        sigaction(SIGPIPE, &previous_pipe, NULL) != 0)
        goto cleanup;
    sigpipe_overridden = 0;
    close(descriptors[1]);
    descriptors[1] = -1;

    child = fork();
    if (child < 0) goto cleanup;
    if (child == 0) _exit(23);
    if (waitpid(child, &status, 0) != child) goto cleanup;
    if (!flyology_subprocess_status_exited(status) ||
        flyology_subprocess_status_exit_code(status) != 23 ||
        flyology_subprocess_status_signaled(status))
        goto cleanup;

    {
        char *child_arguments[] = { argv[0], "--bootstrap-child", NULL };
        char *child_environment[] = { NULL };
        char control = 0;
        char capability = 0;

        if (socketpair(AF_UNIX, SOCK_STREAM, 0, bootstrap_control) != 0 ||
            socketpair(AF_UNIX, SOCK_STREAM, 0, bootstrap_capability) != 0 ||
            fcntl(bootstrap_control[0], F_SETFD, FD_CLOEXEC) != 0 ||
            fcntl(bootstrap_control[1], F_SETFD, FD_CLOEXEC) != 0 ||
            fcntl(bootstrap_capability[0], F_SETFD, FD_CLOEXEC) != 0 ||
            fcntl(bootstrap_capability[1], F_SETFD, FD_CLOEXEC) != 0 ||
            move_above_bootstrap(&bootstrap_control[0]) != 0 ||
            move_above_bootstrap(&bootstrap_control[1]) != 0 ||
            move_above_bootstrap(&bootstrap_capability[0]) != 0 ||
            move_above_bootstrap(&bootstrap_capability[1]) != 0 ||
            bootstrap_control[0] <= 4 || bootstrap_control[1] <= 4 ||
            bootstrap_capability[0] <= 4 ||
            bootstrap_capability[1] <= 4 ||
            (fcntl(bootstrap_control[0], F_GETFD) & FD_CLOEXEC) == 0 ||
            (fcntl(bootstrap_control[1], F_GETFD) & FD_CLOEXEC) == 0 ||
            flyology_subprocess_pipe(input) != 0 ||
            flyology_subprocess_pipe(output) != 0 ||
            flyology_subprocess_pipe(error) != 0)
            goto cleanup;
        if (flyology_subprocess_spawn
              (&child, argv[0], child_arguments, 1, child_environment,
               NULL, 0, input[0], input[1], output[0], output[1],
               error[0], error[1],
               bootstrap_control[0], bootstrap_control[1],
               bootstrap_capability[0], bootstrap_capability[1], 3, 4) != 0)
            goto cleanup;
        live_child = child;
        close(bootstrap_control[1]); bootstrap_control[1] = -1;
        close(bootstrap_capability[1]); bootstrap_capability[1] = -1;
        for (int index = 0; index < 2; ++index) {
            close(input[index]); input[index] = -1;
            close(output[index]); output[index] = -1;
            close(error[index]); error[index] = -1;
        }
        if (read(bootstrap_control[0], &control, 1) != 1 || control != 'C' ||
            read(bootstrap_capability[0], &capability, 1) != 1 ||
            capability != 'K' || waitpid(child, &status, 0) != child ||
            !flyology_subprocess_status_exited(status) ||
            flyology_subprocess_status_exit_code(status) != 0)
            goto cleanup;
        live_child = -1;
        close(bootstrap_control[0]); bootstrap_control[0] = -1;
        close(bootstrap_capability[0]); bootstrap_capability[0] = -1;
    }

    {
        struct sigaction ignored;
        struct sigaction previous_action;
        sigset_t blocked;
        sigset_t previous_mask;
        char *child_arguments[] = { argv[0], "--wait-for-signal", NULL };
        char *child_environment[] = { NULL };

        memset(&ignored, 0, sizeof(ignored));
        ignored.sa_handler = SIG_IGN;
        sigemptyset(&ignored.sa_mask);
        sigemptyset(&blocked);
        sigaddset(&blocked, SIGTERM);
        if (sigaction(SIGTERM, &ignored, &previous_action) != 0 ||
            pthread_sigmask(SIG_BLOCK, &blocked, &previous_mask) != 0 ||
            flyology_subprocess_pipe(input) != 0 ||
            flyology_subprocess_pipe(output) != 0 ||
            flyology_subprocess_pipe(error) != 0)
            goto cleanup;
        if (flyology_subprocess_spawn
              (&child, argv[0], child_arguments, 1, child_environment,
               NULL, 0, input[0], input[1], output[0], output[1],
               error[0], error[1], -1, -1, -1, -1, 3, 4) != 0)
            goto cleanup;
        live_child = child;
        (void)pthread_sigmask(SIG_SETMASK, &previous_mask, NULL);
        (void)sigaction(SIGTERM, &previous_action, NULL);
        for (int index = 0; index < 2; ++index) {
            close(input[index]); input[index] = -1;
            close(output[index]); output[index] = -1;
            close(error[index]); error[index] = -1;
        }
        if (kill(-child, SIGTERM) != 0 || waitpid(child, &status, 0) != child ||
            !flyology_subprocess_status_signaled(status) ||
            flyology_subprocess_status_signal(status) != SIGTERM)
            goto cleanup;
        live_child = -1;
    }
    result = 0;

cleanup:
    if (sigpipe_overridden)
        (void)sigaction(SIGPIPE, &previous_pipe, NULL);
    if (live_child > 0) {
        (void)kill(-live_child, SIGKILL);
        (void)waitpid(live_child, NULL, 0);
    }
    if (descriptors[0] >= 0) close(descriptors[0]);
    if (descriptors[1] >= 0) close(descriptors[1]);
    for (int index = 0; index < 2; ++index) {
        if (input[index] >= 0) close(input[index]);
        if (output[index] >= 0) close(output[index]);
        if (error[index] >= 0) close(error[index]);
        if (bootstrap_control[index] >= 0) close(bootstrap_control[index]);
        if (bootstrap_capability[index] >= 0)
            close(bootstrap_capability[index]);
    }
    return result;
}
