#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#if defined(__linux__)
#include <linux/memfd.h>
#include <sys/syscall.h>
#endif

#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif
#ifndef O_NOFOLLOW
#define O_NOFOLLOW 0
#endif
#ifndef MSG_CMSG_CLOEXEC
#define MSG_CMSG_CLOEXEC 0
#endif
#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif
#ifndef MFD_CLOEXEC
#define MFD_CLOEXEC 0x0001U
#endif
#ifndef MFD_ALLOW_SEALING
#define MFD_ALLOW_SEALING 0x0002U
#endif
#ifndef MFD_NOEXEC_SEAL
#define MFD_NOEXEC_SEAL 0x0008U
#endif
#ifndef F_ADD_SEALS
#define F_ADD_SEALS 1033
#endif
#ifndef F_GET_SEALS
#define F_GET_SEALS 1034
#endif
#ifndef F_SEAL_SEAL
#define F_SEAL_SEAL 0x0001
#endif
#ifndef F_SEAL_SHRINK
#define F_SEAL_SHRINK 0x0002
#endif
#ifndef F_SEAL_GROW
#define F_SEAL_GROW 0x0004
#endif
#ifndef F_SEAL_EXEC
#define F_SEAL_EXEC 0x0020
#endif

#if defined(__APPLE__)
#define FLYOLOGY_SHM_CLOEXEC 0
#else
#define FLYOLOGY_SHM_CLOEXEC O_CLOEXEC
#endif

enum {
    FLYOLOGY_PROP_CLOEXEC = 1 << 0,
    FLYOLOGY_PROP_SIZE_IMMUTABLE = 1 << 1,
    FLYOLOGY_PROP_NOEXEC = 1 << 2,
    FLYOLOGY_PROP_NOEXEC_SUPPORTED = 1 << 3,
    FLYOLOGY_PROP_NOFOLLOW = 1 << 4,
    FLYOLOGY_PROP_OWNER_ONLY = 1 << 5
};

enum {
    FLYOLOGY_HANDOFF_PROTOCOL_ERROR = -5,
    FLYOLOGY_HANDOFF_CONTROL_FDS = 512
};

static int flyology_set_cloexec(int fd)
{
    int flags = fcntl(fd, F_GETFD);
    if (flags < 0) return errno;
    if ((flags & FD_CLOEXEC) == 0 && fcntl(fd, F_SETFD, flags | FD_CLOEXEC) < 0)
        return errno;
    return 0;
}

static int flyology_descriptor_properties(int fd, int nofollow,
                                           int *properties,
                                           unsigned long long *length)
{
    struct stat st;
    int flags;
    int result = 0;
    if (fstat(fd, &st) != 0) return errno;
    if (st.st_size < 0) return EOVERFLOW;
    flags = fcntl(fd, F_GETFD);
    if (flags < 0) return errno;
    if ((flags & FD_CLOEXEC) != 0) result |= FLYOLOGY_PROP_CLOEXEC;
    if ((st.st_mode & 077) == 0) result |= FLYOLOGY_PROP_OWNER_ONLY;
    if (nofollow) result |= FLYOLOGY_PROP_NOFOLLOW;
#if defined(__linux__)
    {
        int seals = fcntl(fd, F_GET_SEALS);
        int immutable = F_SEAL_GROW | F_SEAL_SHRINK | F_SEAL_SEAL;
        if (seals >= 0 && (seals & immutable) == immutable)
            result |= FLYOLOGY_PROP_SIZE_IMMUTABLE;
        if (seals >= 0 && (seals & F_SEAL_EXEC) != 0)
            result |= FLYOLOGY_PROP_NOEXEC |
                      FLYOLOGY_PROP_NOEXEC_SUPPORTED;
    }
#endif
    *properties = result;
    *length = (unsigned long long)st.st_size;
    return 0;
}

static int flyology_namespace_matches(int fd, const char *name, int posix)
{
    struct stat expected;
    struct stat current;
    int current_fd = -1;
    int error;
    if (fstat(fd, &expected) != 0) return errno;
    if (posix) {
        current_fd = shm_open(name, O_RDONLY | FLYOLOGY_SHM_CLOEXEC, 0);
        if (current_fd < 0) return errno;
        error = flyology_set_cloexec(current_fd);
        if (error == 0 && fstat(current_fd, &current) != 0) error = errno;
        close(current_fd);
        if (error != 0) return error;
    } else if (lstat(name, &current) != 0) {
        return errno;
    }
    if (expected.st_dev != current.st_dev || expected.st_ino != current.st_ino ||
        (expected.st_mode & S_IFMT) != (current.st_mode & S_IFMT))
        return -4;
    return 0;
}

static int flyology_unlink_matching(int fd, const char *name, int posix)
{
    int error = flyology_namespace_matches(fd, name, posix);
    int result;
    if (error != 0) return error;
    result = posix ? shm_unlink(name) : unlink(name);
    return result == 0 ? 0 : errno;
}

static int flyology_fail_open(int fd, int created, const char *name, int posix,
                              int error)
{
    if (created) {
        int cleanup = flyology_unlink_matching(fd, name, posix);
        if (cleanup != 0) error = cleanup;
    }
    close(fd);
    return error;
}

int flyology_shm_create_anonymous(unsigned long long length, int require_noexec,
                                  int *fd_out, int *properties_out)
{
    int fd = -1;
    int props = 0;
    unsigned long long actual = 0;
#if defined(__linux__)
    unsigned int flags = MFD_CLOEXEC | MFD_ALLOW_SEALING | MFD_NOEXEC_SEAL;
    int noexec_supported = 1;
    fd = (int)syscall(SYS_memfd_create, "flyology", flags);
    if (fd < 0 && errno == EINVAL) {
        noexec_supported = 0;
        flags = MFD_CLOEXEC | MFD_ALLOW_SEALING;
        fd = (int)syscall(SYS_memfd_create, "flyology", flags);
    }
    if (fd < 0) return errno;
    if (ftruncate(fd, (off_t)length) != 0) {
        int saved = errno; close(fd); return saved;
    }
    if (fcntl(fd, F_ADD_SEALS,
              F_SEAL_GROW | F_SEAL_SHRINK | F_SEAL_SEAL) != 0) {
        int saved = errno; close(fd); return saved;
    }
    if (noexec_supported) {
        props |= FLYOLOGY_PROP_NOEXEC | FLYOLOGY_PROP_NOEXEC_SUPPORTED;
    } else if (require_noexec) {
        close(fd); return -3;
    }
#elif defined(__APPLE__)
    unsigned char random_bytes[16];
    char name[64];
    int attempt;
    if (require_noexec) return -3;
    arc4random_buf(random_bytes, sizeof(random_bytes));
    for (attempt = 0; attempt < 128 && fd < 0; ++attempt) {
        snprintf(name, sizeof(name), "/flyology-%02x%02x%02x%02x%02x%02x%02x%02x-%d",
                 random_bytes[0], random_bytes[1], random_bytes[2], random_bytes[3],
                 random_bytes[4], random_bytes[5], random_bytes[6], random_bytes[7],
                 attempt);
        fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
        if (fd < 0 && errno != EEXIST) return errno;
    }
    if (fd < 0) return EEXIST;
    if (flyology_set_cloexec(fd) != 0 ||
        ftruncate(fd, (off_t)length) != 0 || shm_unlink(name) != 0) {
        int saved = errno; shm_unlink(name); close(fd); return saved;
    }
#else
    (void)length; (void)require_noexec; (void)fd_out; (void)properties_out;
    return ENOTSUP;
#endif
    {
        int noexec_props = props;
        int error = flyology_descriptor_properties(fd, 0, &props, &actual);
        if (error != 0) { close(fd); return error; }
        props |= noexec_props;
    }
    if (actual != length) { close(fd); return -1; }
    if ((props & FLYOLOGY_PROP_CLOEXEC) == 0 ||
#if defined(__linux__)
        (props & FLYOLOGY_PROP_SIZE_IMMUTABLE) == 0 ||
#endif
        0) {
        close(fd); return -3;
    }
    *fd_out = fd;
    *properties_out = props;
    return 0;
}

/* mode: 0 create, 1 open, 2 create-or-open. outcome: 0 created, 1 opened,
   2 observed zero length while the creator was still sizing. */
int flyology_shm_open_named(const char *name, unsigned long long length,
                            unsigned int permissions, int mode,
                            int *fd_out, int *properties_out, int *outcome_out)
{
    int fd;
    int created = 0;
    int props = 0;
    unsigned long long actual = 0;
    if (mode == 0 || mode == 2) {
        fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL | FLYOLOGY_SHM_CLOEXEC,
                      (mode_t)permissions);
        if (fd >= 0) created = 1;
        else if (mode == 0 || errno != EEXIST) return errno;
        else fd = shm_open(name, O_RDWR | FLYOLOGY_SHM_CLOEXEC, 0);
    } else {
        fd = shm_open(name, O_RDWR | FLYOLOGY_SHM_CLOEXEC, 0);
    }
    if (fd < 0) return errno;
    {
        int error = flyology_set_cloexec(fd);
        if (error != 0)
            return flyology_fail_open(fd, created, name, 1, error);
    }
    if (created && ftruncate(fd, (off_t)length) != 0) {
        return flyology_fail_open(fd, 1, name, 1, errno);
    }
    {
        int error = flyology_descriptor_properties(fd, 0, &props, &actual);
        if (error != 0)
            return flyology_fail_open(fd, created, name, 1, error);
    }
    if ((props & FLYOLOGY_PROP_CLOEXEC) == 0)
        return flyology_fail_open(fd, created, name, 1, -3);
    if (!created && actual == 0) {
        close(fd); *outcome_out = 2; return 0;
    }
    if (actual != length)
        return flyology_fail_open(fd, created, name, 1, -1);
    *fd_out = fd;
    *properties_out = props;
    *outcome_out = created ? 0 : 1;
    return 0;
}

int flyology_shm_open_file(const char *path, unsigned long long length,
                           unsigned int permissions, int create,
                           int *fd_out, int *properties_out)
{
    int open_flags = O_RDWR | O_CLOEXEC | O_NOFOLLOW;
    int fd;
    int props = 0;
    unsigned long long actual = 0;
    struct stat st;
    if (create) open_flags |= O_CREAT | O_EXCL;
    fd = open(path, open_flags, (mode_t)permissions);
    if (fd < 0) return errno;
    {
        int error = flyology_set_cloexec(fd);
        if (error != 0)
            return flyology_fail_open(fd, create, path, 0, error);
    }
    if (fstat(fd, &st) != 0)
        return flyology_fail_open(fd, create, path, 0, errno);
    if (!S_ISREG(st.st_mode))
        return flyology_fail_open(fd, create, path, 0, -2);
    if (create && ftruncate(fd, (off_t)length) != 0) {
        return flyology_fail_open(fd, 1, path, 0, errno);
    }
    {
        int error = flyology_descriptor_properties(fd, O_NOFOLLOW != 0,
                                                    &props, &actual);
        if (error != 0)
            return flyology_fail_open(fd, create, path, 0, error);
    }
    if (actual != length)
        return flyology_fail_open(fd, create, path, 0, -1);
    *fd_out = fd;
    *properties_out = props;
    return 0;
}

int flyology_shm_validate_received(int fd, unsigned long long expected,
                                   int require_immutable, int *properties_out)
{
    int props = 0;
    unsigned long long actual = 0;
    struct stat st;
    int status_flags;
    int error = flyology_set_cloexec(fd);
    if (error != 0) return error;
    if (fstat(fd, &st) != 0) return errno;
#if defined(__APPLE__)
    /* Darwin POSIX shm descriptors report only permission bits in st_mode;
       ordinary regular files retain S_IFREG. Reject every other typed fd. */
    if (!S_ISREG(st.st_mode) && (st.st_mode & S_IFMT) != 0) return -2;
#else
    if (!S_ISREG(st.st_mode)) return -2;
#endif
    status_flags = fcntl(fd, F_GETFL);
    if (status_flags < 0) return errno;
    if ((status_flags & O_ACCMODE) != O_RDWR) return -2;
    error = flyology_descriptor_properties(fd, 0, &props, &actual);
    if (error != 0) return error;
    if (actual != expected) return -1;
    if ((props & FLYOLOGY_PROP_CLOEXEC) == 0) return -3;
    if (require_immutable && (props & FLYOLOGY_PROP_SIZE_IMMUTABLE) == 0)
        return -3;
    *properties_out = props;
    return 0;
}

int flyology_shm_map(int fd, unsigned long long length, void **base_out)
{
    void *base = mmap(NULL, (size_t)length, PROT_READ | PROT_WRITE,
                      MAP_SHARED, fd, 0);
    if (base == MAP_FAILED) return errno;
    *base_out = base;
    return 0;
}

int flyology_shm_unmap(void *base, unsigned long long length)
{
    return munmap(base, (size_t)length) == 0 ? 0 : errno;
}

int flyology_shm_msync(void *base, unsigned long long length, int synchronous)
{
    return msync(base, (size_t)length, synchronous ? MS_SYNC : MS_ASYNC) == 0
        ? 0 : errno;
}

int flyology_shm_fsync(int fd) { return fsync(fd) == 0 ? 0 : errno; }
int flyology_shm_close(int fd) { return close(fd) == 0 ? 0 : errno; }
int flyology_shm_unlink_name(int fd, const char *name, int posix)
{
    return flyology_unlink_matching(fd, name, posix);
}

int flyology_shm_prepare_handoff_socket(int socket_fd)
{
    struct sockaddr_storage local_address;
    struct sockaddr_storage peer_address;
    socklen_t local_length = sizeof(local_address);
    socklen_t peer_length = sizeof(peer_address);
    socklen_t type_length;
    int type;
    int error;

    memset(&local_address, 0, sizeof(local_address));
    memset(&peer_address, 0, sizeof(peer_address));
    type_length = sizeof(type);
    if (getsockopt(socket_fd, SOL_SOCKET, SO_TYPE, &type, &type_length) != 0)
        return errno == ENOTSOCK ? FLYOLOGY_HANDOFF_PROTOCOL_ERROR : errno;
    if (type_length != sizeof(type) || type != SOCK_STREAM)
        return FLYOLOGY_HANDOFF_PROTOCOL_ERROR;
    if (getsockname(socket_fd, (struct sockaddr *)&local_address,
                    &local_length) != 0)
        return errno;
    if (getpeername(socket_fd, (struct sockaddr *)&peer_address,
                    &peer_length) != 0)
        return errno == ENOTCONN ? FLYOLOGY_HANDOFF_PROTOCOL_ERROR : errno;
    if (local_length < sizeof(sa_family_t) ||
        peer_length < sizeof(sa_family_t) ||
        local_address.ss_family != AF_UNIX || peer_address.ss_family != AF_UNIX)
        return FLYOLOGY_HANDOFF_PROTOCOL_ERROR;
    error = flyology_set_cloexec(socket_fd);
    if (error != 0) return error;
#if defined(__APPLE__) && defined(SO_NOSIGPIPE)
    {
        int enabled = 1;
        if (setsockopt(socket_fd, SOL_SOCKET, SO_NOSIGPIPE,
                       &enabled, sizeof(enabled)) != 0)
            return errno;
    }
#endif
    return 0;
}

int flyology_shm_untrusted_handoff_supported(void)
{
#if defined(__linux__)
    return 1;
#else
    return 0;
#endif
}

int flyology_shm_send_fd(int socket_fd, int descriptor)
{
    unsigned char payload = 0x46;
    struct iovec iov = { &payload, sizeof(payload) };
    union { struct cmsghdr align; unsigned char bytes[CMSG_SPACE(sizeof(int))]; } control;
    struct msghdr message;
    struct cmsghdr *header;
    int error = flyology_shm_prepare_handoff_socket(socket_fd);
    if (error != 0) return error;
    memset(&control, 0, sizeof(control));
    memset(&message, 0, sizeof(message));
    message.msg_iov = &iov;
    message.msg_iovlen = 1;
    message.msg_control = control.bytes;
    message.msg_controllen = sizeof(control.bytes);
    header = CMSG_FIRSTHDR(&message);
    header->cmsg_level = SOL_SOCKET;
    header->cmsg_type = SCM_RIGHTS;
    header->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(header), &descriptor, sizeof(descriptor));
    for (;;) {
        ssize_t amount = sendmsg(socket_fd, &message, MSG_NOSIGNAL);
        if (amount == (ssize_t)sizeof(payload)) break;
        if (amount < 0 && errno == EINTR) continue;
        return errno == 0 ? EIO : errno;
    }
    return 0;
}

int flyology_shm_receive_fd(int socket_fd, int *descriptor_out)
{
    unsigned char payload;
    struct iovec iov = { &payload, sizeof(payload) };
    /* Linux documents SCM_MAX_FD as 253. Darwin does not document a bound and
       has leaked installed descriptors when a control buffer truncates. Keep
       a larger aligned buffer as defense in depth, then reject every count but
       one. Untrusted Darwin receipt is rejected by the Ada policy layer. */
    union {
        struct cmsghdr align;
        unsigned char bytes[CMSG_SPACE(sizeof(int) * FLYOLOGY_HANDOFF_CONTROL_FDS)];
    } control;
    struct msghdr message;
    struct msghdr bounded_message;
    struct cmsghdr *header;
    unsigned char *control_end;
    int received = -1;
    size_t count = 0;
    int malformed = 0;
    ssize_t amount;
    int error = flyology_shm_prepare_handoff_socket(socket_fd);
    if (error != 0) return error;
    /* Make any kernel-reported-but-unwritten tail decode as invalid rather
       than as descriptor zero on hosts with broken ancillary lengths. */
    memset(&control, 0xff, sizeof(control));
    memset(&message, 0, sizeof(message));
    message.msg_iov = &iov;
    message.msg_iovlen = 1;
    message.msg_control = control.bytes;
    message.msg_controllen = sizeof(control.bytes);
    do {
        amount = recvmsg(socket_fd, &message, MSG_CMSG_CLOEXEC);
    } while (amount < 0 && errno == EINTR);
    if (amount < 0) return errno;
    bounded_message = message;
    if (bounded_message.msg_controllen > sizeof(control.bytes)) {
        bounded_message.msg_controllen = sizeof(control.bytes);
        malformed = 1;
    }
    control_end = control.bytes + bounded_message.msg_controllen;
    for (header = CMSG_FIRSTHDR(&bounded_message); header != NULL;
         header = CMSG_NXTHDR(&bounded_message, header)) {
        const unsigned char *position = (const unsigned char *)header;
        size_t available = position <= control_end
            ? (size_t)(control_end - position) : 0;
        size_t bounded_length;
        size_t data_offset;
        size_t bytes;
        size_t descriptors;
        size_t index;
        const unsigned char *data;

        if (available < CMSG_LEN(0) || header->cmsg_len < CMSG_LEN(0)) {
            malformed = 1;
            break;
        }
        bounded_length = header->cmsg_len < available
            ? header->cmsg_len : available;
        data = CMSG_DATA(header);
        data_offset = (size_t)(data - position);
        if (data_offset > bounded_length) {
            malformed = 1;
            break;
        }
        bytes = bounded_length - data_offset;
        if (header->cmsg_level != SOL_SOCKET ||
            header->cmsg_type != SCM_RIGHTS) {
            malformed = 1;
        } else {
            if (bytes % sizeof(int) != 0) malformed = 1;
            descriptors = bytes / sizeof(int);
            for (index = 0; index < descriptors; ++index) {
                int fd;
                memcpy(&fd, data + index * sizeof(int), sizeof(fd));
                if (fd < 0) {
                    malformed = 1;
                } else if (count == 0) {
                    received = fd;
                } else {
                    close(fd);
                }
                ++count;
            }
        }
        if (header->cmsg_len > available) {
            malformed = 1;
            break;
        }
    }
    if (amount != 1 || payload != 0x46 || malformed ||
        (message.msg_flags & (MSG_CTRUNC | MSG_TRUNC)) != 0 || count != 1) {
        if (received >= 0) close(received);
        return FLYOLOGY_HANDOFF_PROTOCOL_ERROR;
    }
    {
        int cloexec_error = flyology_set_cloexec(received);
        if (cloexec_error != 0) { close(received); return cloexec_error; }
    }
    *descriptor_out = received;
    return 0;
}

uint32_t flyology_shm_atomic_load_u32(const void *address)
{
    return __atomic_load_n((const uint32_t *)address, __ATOMIC_ACQUIRE);
}

uint64_t flyology_shm_atomic_load_u64(const void *address)
{
    return __atomic_load_n((const uint64_t *)address, __ATOMIC_ACQUIRE);
}

void flyology_shm_atomic_store_u32(void *address, uint32_t value)
{
    __atomic_store_n((uint32_t *)address, value, __ATOMIC_RELEASE);
}

void flyology_shm_atomic_store_u64(void *address, uint64_t value)
{
    __atomic_store_n((uint64_t *)address, value, __ATOMIC_RELEASE);
}

int flyology_shm_atomic_cas_u32(void *address, uint32_t *expected,
                                uint32_t desired)
{
    return __atomic_compare_exchange_n((uint32_t *)address, expected, desired,
                                       0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE);
}

void flyology_shm_copy_in(void *target, const void *source, size_t length)
{
    memcpy(target, source, length);
}

int flyology_shm_equal(const void *left, const void *right, size_t length)
{
    return memcmp(left, right, length) == 0;
}

void flyology_shm_zero(void *target, size_t length) { memset(target, 0, length); }
