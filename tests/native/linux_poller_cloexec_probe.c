#define _GNU_SOURCE

#include <dirent.h>
#include <string.h>
#include <unistd.h>

/* Test-only leaf around libc-owned DIR and dirent ABI types.  This only
 * enumerates exact procfs link targets; Ada owns the pass/fail policy.
 */
static int flyology_test_linux_fd_target_count(const char *expected) {
    DIR *directory = opendir("/proc/self/fd");
    struct dirent *entry;
    int count = 0;
    int directory_fd;

    if (directory == NULL) return -1;
    directory_fd = dirfd(directory);
    while ((entry = readdir(directory)) != NULL) {
        char target[128];
        ssize_t length;

        if (entry->d_name[0] == '.') continue;
        length = readlinkat(directory_fd, entry->d_name, target, sizeof(target) - 1);
        if (length < 0) continue;
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
