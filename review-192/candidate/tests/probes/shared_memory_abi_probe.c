#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

/*
 * Focused ABI comparison for the production shared-memory C leaves. The
 * probe compares each layout-dependent observation with the host C API; it
 * contains no Flyology retry, validation, ownership, or cleanup policy.
 */

#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

#ifndef MSG_CMSG_CLOEXEC
#define MSG_CMSG_CLOEXEC 0
#endif

int flyology_shm_fstat_fields(int, long long *, unsigned long long *,
                              unsigned long long *, unsigned int *);
int flyology_shm_lstat_fields(const char *, long long *,
                              unsigned long long *, unsigned long long *,
                              unsigned int *);
int flyology_shm_fcntl_getfd(int);
int flyology_shm_fcntl_setfd(int, int);
int flyology_shm_fcntl_getfl(int);
int flyology_shm_getsockname_family(int, int *);
int flyology_shm_getpeername_family(int, int *);
#if defined(__APPLE__)
int flyology_shm_socket_accepting(int, int *);
#endif
long flyology_shm_send_fd_once(int, int);
long flyology_shm_receive_fds_once(int, int, int *, size_t, size_t *,
                                   unsigned char *, int *, int *);

static int stat_matches(int descriptor, const char *path)
{
    struct stat direct;
    long long size;
    unsigned long long device;
    unsigned long long inode;
    unsigned int mode;
    if (fstat(descriptor, &direct) != 0 ||
        flyology_shm_fstat_fields(descriptor, &size, &device, &inode, &mode) != 0)
        return 0;
    if (size != (long long)direct.st_size ||
        device != (unsigned long long)direct.st_dev ||
        inode != (unsigned long long)direct.st_ino ||
        mode != (unsigned int)direct.st_mode)
        return 0;
    if (lstat(path, &direct) != 0 ||
        flyology_shm_lstat_fields(path, &size, &device, &inode, &mode) != 0)
        return 0;
    return size == (long long)direct.st_size &&
           device == (unsigned long long)direct.st_dev &&
           inode == (unsigned long long)direct.st_ino &&
           mode == (unsigned int)direct.st_mode;
}

static int socket_accepting(int descriptor, int *accepting)
{
#if defined(__APPLE__)
    return flyology_shm_socket_accepting(descriptor, accepting);
#else
    socklen_t length = sizeof(*accepting);
    return getsockopt(descriptor, SOL_SOCKET, SO_ACCEPTCONN,
                      accepting, &length);
#endif
}

int main(void)
{
    char path[] = "/tmp/flyology-shm-abi-XXXXXX";
    int descriptor = mkstemp(path);
    int pair[2] = { -1, -1 };
    int received[512];
    int local_family = 0;
    int peer_family = 0;
    int listener = -1;
    int accepting = -1;
    int message_flags = 0;
    int malformed = 0;
    size_t count = 0;
    unsigned char payload = 0;
    int result = 1;

    for (size_t index = 0; index < 512; ++index) received[index] = -1;
    _Static_assert(sizeof(off_t) <= sizeof(long long), "off_t ABI scalar");
    _Static_assert(CMSG_SPACE(sizeof(int)) >= CMSG_LEN(sizeof(int)),
                   "cmsghdr payload storage");

    if (descriptor < 0 || ftruncate(descriptor, 4096) != 0)
        goto cleanup;
    if (!stat_matches(descriptor, path))
        goto cleanup;
    if (flyology_shm_fcntl_getfd(descriptor) != fcntl(descriptor, F_GETFD) ||
        flyology_shm_fcntl_getfl(descriptor) != fcntl(descriptor, F_GETFL))
        goto cleanup;
    if (flyology_shm_fcntl_setfd(descriptor, FD_CLOEXEC) != 0 ||
        (fcntl(descriptor, F_GETFD) & FD_CLOEXEC) == 0)
        goto cleanup;
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0)
        goto cleanup;
    if (flyology_shm_getsockname_family(pair[0], &local_family) != 0 ||
        flyology_shm_getpeername_family(pair[0], &peer_family) != 0 ||
        local_family != AF_UNIX || peer_family != AF_UNIX)
        goto cleanup;
    if (socket_accepting(pair[0], &accepting) != 0 ||
        accepting != 0)
        goto cleanup;
    if (unlink(path) != 0)
        goto cleanup;
    listener = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listener < 0) goto cleanup;
    {
        struct sockaddr_un address;
        memset(&address, 0, sizeof(address));
        address.sun_family = AF_UNIX;
        if (strlen(path) >= sizeof(address.sun_path)) goto cleanup;
        memcpy(address.sun_path, path, strlen(path) + 1);
        if (bind(listener, (struct sockaddr *)&address, sizeof(address)) != 0 ||
            listen(listener, 4) != 0)
            goto cleanup;
    }
    if (socket_accepting(listener, &accepting) != 0 ||
        accepting != 1)
        goto cleanup;
    if (flyology_shm_send_fd_once(pair[0], descriptor) != 1)
        goto cleanup;
    if (flyology_shm_receive_fds_once
          (pair[1], MSG_CMSG_CLOEXEC, received, 512, &count, &payload,
           &message_flags, &malformed) != 1)
        goto cleanup;
    if (count != 1 || received[0] < 0 || payload != 0x46 || malformed != 0)
        goto cleanup;
    result = 0;

cleanup:
    for (size_t index = 0; index < 512; ++index)
        if (received[index] >= 0) close(received[index]);
    if (pair[0] >= 0) close(pair[0]);
    if (pair[1] >= 0) close(pair[1]);
    if (listener >= 0) close(listener);
    if (descriptor >= 0) close(descriptor);
    unlink(path);
    return result;
}
