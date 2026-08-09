#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

/*
 * Shared-memory ABI leaves only.
 *
 * This file exists where a direct fixed-signature Ada import would have to
 * reproduce target-dependent C semantics: struct stat and sockaddr field
 * layouts, variadic fcntl commands, the header-selected Linux memfd syscall,
 * and cmsghdr alignment and traversal expressed by the CMSG_* macros.
 *
 * The ancillary receive leaf is consequently longer than the other wrappers.
 * It makes exactly one recvmsg call, bounds every kernel-supplied control
 * length before pointer arithmetic, and exports every observable descriptor to
 * Ada. Those checks make traversal memory-safe; they do not decide whether the
 * message is an acceptable Flyology handoff. The leaf never retries, closes a
 * descriptor, assumes ownership, or mutates Flyology lifecycle state.
 *
 * Ada owns protocol framing, trust and security validation, error
 * classification, retry and syscall sequencing, cleanup, ownership, and
 * lifecycle policy. scripts/check-shared-memory-c-boundary.sh allowlists the
 * exported leaves, and tests/probes/shared_memory_abi_probe.c compares their
 * ABI observations with the host C API.
 */

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
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

#ifndef MSG_CMSG_CLOEXEC
#define MSG_CMSG_CLOEXEC 0
#endif
#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif
#ifndef F_ADD_SEALS
#define F_ADD_SEALS 1033
#endif
#ifndef F_GET_SEALS
#define F_GET_SEALS 1034
#endif

enum { FLYOLOGY_HANDOFF_CONTROL_FDS = 512 };

_Static_assert(sizeof(off_t) <= sizeof(long long),
               "off_t must fit the Ada ABI scalar");
_Static_assert(sizeof(dev_t) <= sizeof(unsigned long long),
               "dev_t must fit the Ada ABI scalar");
_Static_assert(sizeof(ino_t) <= sizeof(unsigned long long),
               "ino_t must fit the Ada ABI scalar");
_Static_assert(sizeof(((struct stat *)0)->st_mode) <= sizeof(unsigned int),
               "st_mode must fit the Ada ABI scalar");
_Static_assert(CMSG_SPACE(sizeof(int)) >= CMSG_LEN(sizeof(int)),
               "ancillary storage must include one descriptor payload");

static void flyology_export_stat(const struct stat *value,
                                 long long *size,
                                 unsigned long long *device,
                                 unsigned long long *inode,
                                 unsigned int *mode)
{
    *size = (long long)value->st_size;
    *device = (unsigned long long)value->st_dev;
    *inode = (unsigned long long)value->st_ino;
    *mode = (unsigned int)value->st_mode;
}

int flyology_shm_fstat_fields(int descriptor,
                              long long *size,
                              unsigned long long *device,
                              unsigned long long *inode,
                              unsigned int *mode)
{
    struct stat value;
    int result = fstat(descriptor, &value);
    if (result == 0) flyology_export_stat(&value, size, device, inode, mode);
    return result;
}

int flyology_shm_lstat_fields(const char *path,
                              long long *size,
                              unsigned long long *device,
                              unsigned long long *inode,
                              unsigned int *mode)
{
    struct stat value;
    int result = lstat(path, &value);
    if (result == 0) flyology_export_stat(&value, size, device, inode, mode);
    return result;
}

int flyology_shm_fcntl_getfd(int descriptor)
{
    return fcntl(descriptor, F_GETFD);
}

int flyology_shm_fcntl_setfd(int descriptor, int flags)
{
    return fcntl(descriptor, F_SETFD, flags);
}

int flyology_shm_fcntl_getfl(int descriptor)
{
    return fcntl(descriptor, F_GETFL);
}

int flyology_shm_fcntl_get_seals(int descriptor)
{
    return fcntl(descriptor, F_GET_SEALS);
}

int flyology_shm_fcntl_add_seals(int descriptor, int seals)
{
    return fcntl(descriptor, F_ADD_SEALS, seals);
}

int flyology_shm_memfd_create(unsigned int flags)
{
#if defined(__linux__)
    return (int)syscall(SYS_memfd_create, "flyology", flags);
#else
    (void)flags;
    errno = ENOTSUP;
    return -1;
#endif
}

int flyology_shm_getsockname_family(int descriptor, int *family)
{
    struct sockaddr_storage address;
    socklen_t length = sizeof(address);
    int result;
    memset(&address, 0, sizeof(address));
    result = getsockname(descriptor, (struct sockaddr *)&address, &length);
    *family = result == 0 && length >= sizeof(sa_family_t)
        ? (int)address.ss_family : -1;
    return result;
}

int flyology_shm_getpeername_family(int descriptor, int *family)
{
    struct sockaddr_storage address;
    socklen_t length = sizeof(address);
    int result;
    memset(&address, 0, sizeof(address));
    result = getpeername(descriptor, (struct sockaddr *)&address, &length);
    *family = result == 0 && length >= sizeof(sa_family_t)
        ? (int)address.ss_family : -1;
    return result;
}

long flyology_shm_send_fd_once(int socket_fd, int descriptor)
{
    unsigned char payload = 0x46;
    struct iovec iov = { &payload, sizeof(payload) };
    union {
        struct cmsghdr align;
        unsigned char bytes[CMSG_SPACE(sizeof(int))];
    } control;
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
    return (long)sendmsg(socket_fd, &message, MSG_NOSIGNAL);
}

long flyology_shm_receive_fds_once(int socket_fd,
                                    int flags,
                                    int *descriptors_out,
                                    size_t capacity,
                                    size_t *count_out,
                                    unsigned char *payload_out,
                                    int *message_flags_out,
                                    int *malformed_out)
{
    unsigned char payload = 0;
    struct iovec iov = { &payload, sizeof(payload) };
    union {
        struct cmsghdr align;
        unsigned char bytes[
            CMSG_SPACE(sizeof(int) * FLYOLOGY_HANDOFF_CONTROL_FDS)];
    } control;
    struct msghdr message;
    struct msghdr bounded_message;
    struct cmsghdr *header;
    unsigned char *control_end;
    size_t count = 0;
    int malformed = 0;
    ssize_t amount;

    if (capacity < FLYOLOGY_HANDOFF_CONTROL_FDS) {
        errno = EINVAL;
        return -1;
    }
    memset(&control, 0xff, sizeof(control));
    memset(&message, 0, sizeof(message));
    message.msg_iov = &iov;
    message.msg_iovlen = 1;
    message.msg_control = control.bytes;
    message.msg_controllen = sizeof(control.bytes);
    amount = recvmsg(socket_fd, &message, flags);
    if (amount < 0) return (long)amount;

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
        size_t descriptor_count;
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
            descriptor_count = bytes / sizeof(int);
            for (index = 0; index < descriptor_count; ++index) {
                int descriptor;
                memcpy(&descriptor, data + index * sizeof(int),
                       sizeof(descriptor));
                descriptors_out[count++] = descriptor;
            }
        }
        if (header->cmsg_len > available) {
            malformed = 1;
            break;
        }
    }
    *count_out = count;
    *payload_out = payload;
    *message_flags_out = message.msg_flags;
    *malformed_out = malformed;
    return (long)amount;
}
