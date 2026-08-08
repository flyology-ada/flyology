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
        if (error != 0) { close(fd); return error; }
    }
    if (created && ftruncate(fd, (off_t)length) != 0) {
        int saved = errno; close(fd); shm_unlink(name); return saved;
    }
    {
        int error = flyology_descriptor_properties(fd, 0, &props, &actual);
        if (error != 0) { close(fd); return error; }
    }
    if ((props & FLYOLOGY_PROP_CLOEXEC) == 0) { close(fd); return -3; }
    if (!created && actual == 0) {
        close(fd); *outcome_out = 2; return 0;
    }
    if (actual != length) { close(fd); return -1; }
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
        if (error != 0) { close(fd); return error; }
    }
    if (fstat(fd, &st) != 0) { int saved = errno; close(fd); return saved; }
    if (!S_ISREG(st.st_mode)) { close(fd); return -2; }
    if (create && ftruncate(fd, (off_t)length) != 0) {
        int saved = errno; close(fd); unlink(path); return saved;
    }
    {
        int error = flyology_descriptor_properties(fd, O_NOFOLLOW != 0,
                                                    &props, &actual);
        if (error != 0) { close(fd); return error; }
    }
    if (actual != length) { close(fd); return -1; }
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
int flyology_shm_unlink_name(const char *name, int posix)
{
    int result = posix ? shm_unlink(name) : unlink(name);
    return result == 0 || errno == ENOENT ? 0 : errno;
}

int flyology_shm_send_fd(int socket_fd, int descriptor)
{
    unsigned char payload = 0x46;
    struct iovec iov = { &payload, sizeof(payload) };
    union { struct cmsghdr align; unsigned char bytes[CMSG_SPACE(sizeof(int))]; } control;
    struct msghdr message;
    struct cmsghdr *header;
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
    if (sendmsg(socket_fd, &message, MSG_NOSIGNAL) != (ssize_t)sizeof(payload))
        return errno == 0 ? EIO : errno;
    return 0;
}

int flyology_shm_receive_fd(int socket_fd, int *descriptor_out)
{
    unsigned char payload;
    struct iovec iov = { &payload, sizeof(payload) };
    union { struct cmsghdr align; unsigned char bytes[CMSG_SPACE(sizeof(int) * 16)]; } control;
    struct msghdr message;
    struct cmsghdr *header;
    int received[16];
    size_t count = 0;
    int malformed = 0;
    ssize_t amount;
    memset(&control, 0, sizeof(control));
    memset(&message, 0, sizeof(message));
    message.msg_iov = &iov;
    message.msg_iovlen = 1;
    message.msg_control = control.bytes;
    message.msg_controllen = sizeof(control.bytes);
    amount = recvmsg(socket_fd, &message, MSG_CMSG_CLOEXEC);
    if (amount < 0) return errno;
    for (header = CMSG_FIRSTHDR(&message); header != NULL;
         header = CMSG_NXTHDR(&message, header)) {
        if (header->cmsg_level == SOL_SOCKET && header->cmsg_type == SCM_RIGHTS &&
            header->cmsg_len >= CMSG_LEN(0)) {
            size_t bytes = header->cmsg_len - CMSG_LEN(0);
            size_t descriptors = bytes / sizeof(int);
            size_t index;
            const unsigned char *data = CMSG_DATA(header);
            if (bytes % sizeof(int) != 0) malformed = 1;
            for (index = 0; index < descriptors; ++index) {
                int fd;
                memcpy(&fd, data + index * sizeof(int), sizeof(fd));
                if (count < 16) received[count++] = fd;
                else close(fd);
            }
        }
    }
    if (amount != 1 || payload != 0x46 || malformed ||
        (message.msg_flags & MSG_CTRUNC) != 0 || count != 1) {
        size_t index;
        for (index = 0; index < count; ++index) close(received[index]);
        return EBADMSG;
    }
    {
        int error = flyology_set_cloexec(received[0]);
        if (error != 0) { close(received[0]); return error; }
    }
    *descriptor_out = received[0];
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
