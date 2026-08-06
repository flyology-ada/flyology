#define _POSIX_C_SOURCE 200809L

#include <fcntl.h>
#include <limits.h>
#include <unistd.h>

/* Test-only observability for ensuring operations that cannot wait on a
 * cancellation source do not allocate one as a side effect. */
int flyology_test_open_fd_count(void) {
    int count = 0;
    long configured_limit = sysconf(_SC_OPEN_MAX);
    int limit = configured_limit > 0 && configured_limit <= INT_MAX
      ? (int) configured_limit : 1024;

    for (int fd = 0; fd < limit; ++fd) {
        if (fcntl(fd, F_GETFD) >= 0) {
            ++count;
        }
    }
    return count;
}

int flyology_test_fd_is_open(int fd) {
    return fcntl(fd, F_GETFD) >= 0;
}

int flyology_test_fd_is_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL);

    return flags >= 0 && (flags & O_NONBLOCK) != 0;
}

int flyology_test_fd_is_close_on_exec(int fd) {
    int flags = fcntl(fd, F_GETFD);

    return flags >= 0 && (flags & FD_CLOEXEC) != 0;
}
