#if defined(__linux__)
#include <errno.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <stddef.h>
#include <signal.h>
#include <sys/epoll.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

int flyology_test_epoll_pwait2_available(void) {
#ifdef SYS_epoll_pwait2
    const struct timespec immediate = { 0, 0 };
    struct epoll_event event;
    int descriptor = epoll_create1(EPOLL_CLOEXEC);
    int result;
    int error;

    if (descriptor < 0) {
        return -1;
    }
    result = syscall(SYS_epoll_pwait2, descriptor, &event, 1,
                     &immediate, NULL, _NSIG / 8);
    error = errno;
    close(descriptor);
    if (result == 0) {
        return 1;
    }
    return error == ENOSYS ? 0 : -1;
#else
    return 0;
#endif
}

/* Only the calling thread is filtered. Test both syscall choices without
   requiring an old kernel or timing assumptions about the host scheduler. */
static int block_syscall(int number, int error_code) {
    struct sock_filter instructions[] = {
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, number, 0, 1),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | error_code),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
    };
    struct sock_fprog program = {
        .len = sizeof(instructions) / sizeof(instructions[0]),
        .filter = instructions,
    };

    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) {
        return -1;
    }
    return prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &program);
}

int flyology_test_block_epoll_pwait2(void) {
#ifdef SYS_epoll_pwait2
    return block_syscall(SYS_epoll_pwait2, ENOSYS);
#else
    /* The bridge itself returns ENOSYS when target headers lack the number. */
    return 0;
#endif
}

int flyology_test_block_epoll_wait(void) {
#ifdef SYS_epoll_wait
    return block_syscall(SYS_epoll_wait, EIO);
#else
    /* AArch64 has no epoll_wait syscall; glibc implements it with epoll_pwait. */
    return block_syscall(SYS_epoll_pwait, EIO);
#endif
}
#else
int flyology_test_epoll_pwait2_available(void) { return -1; }
int flyology_test_block_epoll_pwait2(void) { return -1; }
int flyology_test_block_epoll_wait(void) { return -1; }
#endif
