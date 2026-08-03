#include <fcntl.h>

/* Keep the variadic fcntl ABI outside Ada.  In particular, Darwin/AArch64
 * passes variadic arguments differently from ordinary fixed arguments. */
int flyology_wake_source_configure(int fd)
{
    int status_flags = fcntl(fd, F_GETFL);
    int descriptor_flags;

    if (status_flags < 0 ||
        fcntl(fd, F_SETFL, status_flags | O_NONBLOCK) < 0) {
        return -1;
    }

    descriptor_flags = fcntl(fd, F_GETFD);
    if (descriptor_flags < 0 ||
        fcntl(fd, F_SETFD, descriptor_flags | FD_CLOEXEC) < 0) {
        return -1;
    }

    return 0;
}
