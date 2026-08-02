#include <fcntl.h>
#include <unistd.h>

/* Test-only observability for ensuring operations that cannot wait on a
 * cancellation source do not allocate one as a side effect. */
int gnatevl_test_open_fd_count(void) {
    int count = 0;
    int limit = getdtablesize();

    for (int fd = 0; fd < limit; ++fd) {
        if (fcntl(fd, F_GETFD) >= 0) {
            ++count;
        }
    }
    return count;
}
