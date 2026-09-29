#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>

/* Test-only leaf around libc-owned DIR and dirent ABI types, which do not
 * have a stable direct Ada representation.  This only enumerates exact
 * procfs link targets; Ada owns result validation and pass/fail policy.
 */
static int flyology_test_linux_fd_target_count(const char *expected) {
    DIR *directory = opendir("/proc/self/fd");
    struct dirent *entry;
    int count = 0;
    int directory_fd;

    if (directory == NULL) return -1;
    directory_fd = dirfd(directory);
    if (directory_fd < 0) {
        (void)closedir(directory);
        return -1;
    }

    for (;;) {
        char target[128];
        ssize_t length;

        errno = 0;
        entry = readdir(directory);
        if (entry == NULL) {
            if (errno != 0) count = -1;
            break;
        }

        if (entry->d_name[0] == '.') continue;
        length = readlinkat(directory_fd, entry->d_name, target, sizeof(target) - 1);
        if (length < 0 || (size_t)length >= sizeof(target) - 1) {
            count = -1;
            break;
        }
        target[length] = '\0';
        if (strcmp(target, expected) == 0) ++count;
    }
    if (closedir(directory) != 0) return -1;
    return count;
}

int flyology_test_linux_eventpoll_fd_count(void) {
    return flyology_test_linux_fd_target_count("anon_inode:[eventpoll]");
}

int flyology_test_linux_eventfd_fd_count(void) {
    return flyology_test_linux_fd_target_count("anon_inode:[eventfd]");
}
