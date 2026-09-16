#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <errno.h>
#include <dirent.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <unistd.h>

static volatile sig_atomic_t flyology_subprocess_stop_requested;
static volatile sig_atomic_t flyology_subprocess_fail_reaper_allocation;

/* Ignore the enumeration handle itself and report the complete sorted set.
   A Linux child may legitimately inherit application-owned descriptors; the
   parent compares this set with a clean pre-churn child. */
int flyology_test_subprocess_descriptor_list(char *buffer, size_t capacity)
{
    DIR *directory = opendir("/dev/fd");
    struct dirent *entry;
    int descriptors[256];
    int directory_fd;
    size_t count = 0;
    size_t length = 0;

    if (directory == NULL) return -1;
    directory_fd = dirfd(directory);
    while ((entry = readdir(directory)) != NULL) {
        char *end;
        long value = strtol(entry->d_name, &end, 10);
        if (*end == '\0' && value > STDERR_FILENO && value != directory_fd) {
            if (value > INT_MAX || count == sizeof(descriptors) / sizeof(descriptors[0])) {
                (void)closedir(directory);
                return -1;
            }
            size_t position = count++;
            while (position > 0 && descriptors[position - 1] > value) {
                descriptors[position] = descriptors[position - 1];
                --position;
            }
            descriptors[position] = (int)value;
        }
    }
    (void)closedir(directory);
    if (capacity == 0) return -1;
    for (size_t index = 0; index < count; ++index) {
        int written = snprintf(buffer + length, capacity - length, "%s%d",
                               index == 0 ? "" : ",", descriptors[index]);
        if (written < 0 || (size_t)written >= capacity - length) return -1;
        length += (size_t)written;
    }
    return (int)length;
}

void flyology_test_subprocess_set_fail_reaper_allocation(int enabled)
{
    flyology_subprocess_fail_reaper_allocation = enabled != 0;
}

int flyology_test_subprocess_fail_reaper_allocation(void)
{
    return flyology_subprocess_fail_reaper_allocation != 0;
}

static void flyology_subprocess_handle_term(int signal_number)
{
    (void)signal_number;
    flyology_subprocess_stop_requested = 1;
}

int flyology_test_subprocess_install_term_handler(void)
{
    struct sigaction action;
    sigemptyset(&action.sa_mask);
    action.sa_handler = flyology_subprocess_handle_term;
    action.sa_flags = 0;
    flyology_subprocess_stop_requested = 0;
    return sigaction(SIGTERM, &action, NULL);
}

int flyology_test_subprocess_term_requested(void)
{
    return flyology_subprocess_stop_requested != 0;
}

int flyology_test_subprocess_ignore_term(void)
{
    struct sigaction action;
    sigemptyset(&action.sa_mask);
    action.sa_handler = SIG_IGN;
    action.sa_flags = 0;
    return sigaction(SIGTERM, &action, NULL);
}

int flyology_test_subprocess_fork_descendant(void)
{
    pid_t child = fork();
    if (child < 0) return -1;
    if (child == 0) {
        (void)flyology_test_subprocess_ignore_term();
        for (;;) pause();
    }
    return (int)child;
}

int flyology_test_subprocess_fork_output_writer(void)
{
    pid_t child = fork();
    if (child < 0) return -1;
    if (child == 0) {
        char bytes[4096];
        for (size_t index = 0; index < sizeof(bytes); ++index)
            bytes[index] = 'W';
        for (;;) {
            ssize_t result = write(STDOUT_FILENO, bytes, sizeof(bytes));
            if (result <= 0) _exit(0);
        }
    }
    return (int)child;
}

int flyology_test_subprocess_fork_escaped_pipe_holder(void)
{
    pid_t child = fork();
    if (child < 0) return -1;
    if (child == 0) {
        if (setsid() < 0) _exit(96);
        alarm(2);
        for (;;) pause();
    }
    return (int)child;
}

int flyology_test_subprocess_pid_exists(int pid)
{
    if (kill((pid_t)pid, 0) == 0) return 1;
    return errno == EPERM ? 1 : 0;
}
