#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

extern int gnatevl_runtime_observe_lifecycle(void);
extern int gnatevl_runtime_observe_created_groups(void);
struct runtime_group_snapshot {
    unsigned version;
    int thread_state;
    int dedicated;
    int reserved;
    unsigned long long members;
    unsigned long long pinned_members;
    unsigned long long ready;
    unsigned long long waiting;
    unsigned long long running;
    unsigned long long migrating;
    unsigned long long finished;
    unsigned long long timer_waits;
    unsigned long long descriptor_waits;
    unsigned long long interrupt_waits;
    unsigned long long file_waits;
    unsigned long long pending_file_submissions;
    unsigned long long dispatches;
    unsigned long long poll_batches;
    unsigned long long poll_events;
    unsigned long long wakeups;
    unsigned long long migrations_in;
    unsigned long long migrations_out;
};
extern int gnatevl_runtime_observe_group(
    int group, struct runtime_group_snapshot *snapshot, size_t size);

static int expected_state;
static int expected_groups;
static volatile sig_atomic_t signal_count;

static void check_lifecycle_at_exit(void) {
    int state = gnatevl_runtime_observe_lifecycle();
    int groups = gnatevl_runtime_observe_created_groups();

    if (state != expected_state || groups != expected_groups) {
        char message[160];
        int length = snprintf(message, sizeof(message),
            "GNATEVL lifecycle exit check failed: state=%d groups=%d "
            "expected_state=%d expected_groups=%d\n",
            state, groups, expected_state, expected_groups);
        if (length > 0) {
            (void)write(STDERR_FILENO, message, (size_t)length);
        }
        if (groups > 0) {
            struct runtime_group_snapshot snapshot;
            if (gnatevl_runtime_observe_group(
                    0, &snapshot, sizeof(snapshot)) == 1) {
                length = snprintf(message, sizeof(message),
                    "group0 members=%llu ready=%llu waiting=%llu "
                    "running=%llu finished=%llu timers=%llu io=%llu\n",
                    snapshot.members, snapshot.ready, snapshot.waiting,
                    snapshot.running, snapshot.finished,
                    snapshot.timer_waits, snapshot.descriptor_waits);
                if (length > 0) {
                    (void)write(STDERR_FILENO, message, (size_t)length);
                }
            }
        }
        _Exit(97);
    }
}

int gnatevl_test_arm_exit_check(int state, int groups) {
    expected_state = state;
    expected_groups = groups;
    return atexit(check_lifecycle_at_exit);
}

static void count_signal(int signo) {
    (void)signo;
    signal_count = 1;
}

int gnatevl_test_signal_thread(uintptr_t raw_thread) {
    struct sigaction action;

    action.sa_handler = count_signal;
    sigemptyset(&action.sa_mask);
    action.sa_flags = 0;
    signal_count = 0;
    if (sigaction(SIGUSR1, &action, NULL) != 0) {
        return -1;
    }
    if (pthread_kill((pthread_t)raw_thread, SIGUSR1) != 0) {
        return -1;
    }
    for (int attempt = 0; attempt < 1000 && signal_count == 0; ++attempt) {
        usleep(1000);
    }
    return signal_count == 1 ? 0 : -1;
}

int gnatevl_test_fork_exec(const char *program) {
    pid_t child = fork();
    int status;

    if (child < 0) {
        return -1;
    }
    if (child == 0) {
        if (gnatevl_runtime_observe_lifecycle() != 5) {
            _Exit(91);
        }
        execl(program, program, (char *)NULL);
        _Exit(92);
    }

    for (int attempt = 0; attempt < 5000; ++attempt) {
        pid_t result = waitpid(child, &status, WNOHANG);
        if (result == child) {
            return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : -1;
        }
        if (result < 0 && errno != EINTR) {
            return -1;
        }
        usleep(1000);
    }

    (void)kill(child, SIGKILL);
    (void)waitpid(child, &status, 0);
    return -1;
}
