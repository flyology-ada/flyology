#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

/*
 * Showcase-only process ABI leaves.
 *
 * Ada owns descriptor lifetime, worker policy, timeouts, failure handling, and
 * cleanup. C is retained because posix_spawn_file_actions_t is opaque and the
 * wait-status predicates are macros without a linkable ABI. Socket creation
 * also establishes close-on-exec on both initial endpoints, using
 * SOCK_CLOEXEC or variadic fcntl as selected by host headers. The spawn action
 * duplicates the one intended child endpoint onto descriptor 3; dup2 clears
 * close-on-exec only for that exec boundary. Child observation makes one
 * waitpid call. The spawn leaf otherwise performs only the sequencing needed
 * to construct and destroy the opaque action object around one posix_spawn.
 */

#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdio.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

_Static_assert(sizeof(pid_t) <= sizeof(int),
               "pid_t must fit the Ada showcase scalar");

int flyology_showcase_image_socketpair(int *left, int *right)
{
    int pair[2];
#if defined(SOCK_CLOEXEC)
    if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, pair) != 0)
        return -1;
#else
    int first_flags;
    int second_flags;
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0) return -1;
    first_flags = fcntl(pair[0], F_GETFD);
    second_flags = fcntl(pair[1], F_GETFD);
    if (first_flags < 0 || second_flags < 0
        || fcntl(pair[0], F_SETFD, first_flags | FD_CLOEXEC) != 0
        || fcntl(pair[1], F_SETFD, second_flags | FD_CLOEXEC) != 0) {
        close(pair[0]);
        close(pair[1]);
        return -1;
    }
#endif
    *left = pair[0];
    *right = pair[1];
    return 0;
}

int flyology_showcase_spawn_image_worker(const char *program,
                                          int socket_fd,
                                          const char *corpus,
                                          int worker_id,
                                          unsigned long long segment_length,
                                          int index_capacity,
                                          int width,
                                          int height,
                                          int passes,
                                          int index_rounds,
                                          int *pid_out)
{
    char worker_text[24];
    char length_text[32];
    char capacity_text[24];
    char width_text[24];
    char height_text[24];
    char passes_text[24];
    char rounds_text[24];
    char *arguments[11];
    posix_spawn_file_actions_t actions;
    pid_t child;
    int error;

    snprintf(worker_text, sizeof(worker_text), "%d", worker_id);
    snprintf(length_text, sizeof(length_text), "%llu", segment_length);
    snprintf(capacity_text, sizeof(capacity_text), "%d", index_capacity);
    snprintf(width_text, sizeof(width_text), "%d", width);
    snprintf(height_text, sizeof(height_text), "%d", height);
    snprintf(passes_text, sizeof(passes_text), "%d", passes);
    snprintf(rounds_text, sizeof(rounds_text), "%d", index_rounds);
    arguments[0] = (char *)program;
    arguments[1] = (char *)"worker";
    arguments[2] = (char *)corpus;
    arguments[3] = worker_text;
    arguments[4] = length_text;
    arguments[5] = capacity_text;
    arguments[6] = width_text;
    arguments[7] = height_text;
    arguments[8] = passes_text;
    arguments[9] = rounds_text;
    arguments[10] = NULL;

    error = posix_spawn_file_actions_init(&actions);
    if (error != 0) return error;
    error = posix_spawn_file_actions_adddup2(&actions, socket_fd, 3);
    if (error == 0)
        error = posix_spawn(&child, program, &actions, NULL,
                            arguments, environ);
    posix_spawn_file_actions_destroy(&actions);
    if (error != 0) return error;
    *pid_out = (int)child;
    return 0;
}

/* One waitpid observation: 0 running, 1 successful exit, 2 interrupted,
 * -1 failed exit or wait error. */
int flyology_showcase_poll_image_worker(int pid)
{
    int status;
    pid_t result = waitpid((pid_t)pid, &status, WNOHANG);
    if (result == 0) return 0;
    if (result < 0) return errno == EINTR ? 2 : -1;
    return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 1 : -1;
}
