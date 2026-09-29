#include <fcntl.h>

/* Export the target header values without retaining wake-source policy in C. */
const int flyology_wake_source_f_getfd = F_GETFD;
const int flyology_wake_source_f_setfd = F_SETFD;
const int flyology_wake_source_f_getfl = F_GETFL;
const int flyology_wake_source_f_setfl = F_SETFL;
const int flyology_wake_source_fd_cloexec = FD_CLOEXEC;
const int flyology_wake_source_o_nonblock = O_NONBLOCK;
