#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

#if defined(__aarch64__)
__attribute__((noinline))
void flyology_test_sparse_stack_write(size_t distance) {
    uintptr_t stack_pointer;

    __asm__ volatile("mov %0, sp" : "=r"(stack_pointer));
    *(volatile unsigned char *)(stack_pointer - distance) = 0;
}
#elif defined(__x86_64__)
__attribute__((noinline))
void flyology_test_sparse_stack_write(size_t distance) {
    uintptr_t stack_pointer;

    __asm__ volatile("movq %%rsp, %0" : "=r"(stack_pointer));
    *(volatile unsigned char *)(stack_pointer - distance) = 0;
}
#else
#error "stack-guard probe requires a supported Flyology context architecture"
#endif

/* stack_t has no Ada binding in this test. Return one observation only; Ada
   owns the scenario assertions and all runtime stack policy. */
int flyology_test_alt_stack_is_installed(void) {
    stack_t stack;

    if (sigaltstack(NULL, &stack) != 0) return -1;
    return stack.ss_sp != NULL && stack.ss_size != 0 &&
           (stack.ss_flags & SS_DISABLE) == 0;
}

int flyology_test_run_stack_guard_child(const char *program) {
    char *const arguments[] = {(char *)program, (char *)"violate", NULL};
    pid_t child;
    int status;

    if (program == NULL || posix_spawn(
            &child, program, NULL, NULL, arguments, environ) != 0) {
        return -1;
    }

    for (int attempt = 0; attempt < 5000; ++attempt) {
        pid_t result = waitpid(child, &status, WNOHANG);

        if (result == child) {
            if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
                return 0;
            }
            if (WIFSIGNALED(status) &&
                (WTERMSIG(status) == SIGSEGV || WTERMSIG(status) == SIGBUS ||
                 WTERMSIG(status) == SIGILL)) {
                /* GNAT may translate the protection fault to Storage_Error
                   before exception unwinding discovers that the saved SP is
                   itself inside the guard. Darwin then terminates the child
                   with SIGILL. All three outcomes are fail-stop boundaries. */
                return 0;
            }
            if (WIFEXITED(status)) {
                fprintf(stderr, "stack-guard child exited with status %d\n",
                        WEXITSTATUS(status));
            } else if (WIFSIGNALED(status)) {
                fprintf(stderr, "stack-guard child received signal %d\n",
                        WTERMSIG(status));
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
    return -1;
}
