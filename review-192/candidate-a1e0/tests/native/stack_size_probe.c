#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <stddef.h>
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

/* Run one stack-sizing scenario in its own process and report its exit
   status. A rejected stack request must return normally, so a signalled or
   stalled child is a failure rather than an accepted outcome:

     >= 0  child exit status
     -1    spawn failure
     -2    child terminated by a signal
     -3    child did not terminate within the bounded wait */
int flyology_test_run_stack_size_child(const char *program,
                                       const char *scenario) {
    char *const arguments[] = {(char *)program, (char *)scenario, NULL};
    pid_t child;
    int status;

    if (program == NULL || scenario == NULL || posix_spawn(
            &child, program, NULL, NULL, arguments, environ) != 0) {
        return -1;
    }

    for (int attempt = 0; attempt < 10000; ++attempt) {
        pid_t result = waitpid(child, &status, WNOHANG);

        if (result == child) {
            if (WIFEXITED(status)) {
                return WEXITSTATUS(status);
            }
            if (WIFSIGNALED(status)) {
                fprintf(stderr, "stack-size child %s received signal %d\n",
                        scenario, WTERMSIG(status));
                return -2;
            }
            return -1;
        }
        if (result < 0 && errno != EINTR) {
            return -1;
        }
        usleep(1000);
    }

    (void)kill(child, SIGKILL);
    (void)waitpid(child, &status, 0);
    return -3;
}
