#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif
#if defined(__APPLE__) && !defined(__APPLE_USE_RFC_3542)
#define __APPLE_USE_RFC_3542
#endif

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <netinet/in.h>
#include <stdint.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#include "flyology_tls_signal.h"

#if defined(__linux__)
#include <sys/sendfile.h>
#endif

#if !defined(MSG_NOSIGNAL)
#define MSG_NOSIGNAL 0
#endif

#define FLYOLOGY_MAX_IP_DATAGRAM 65535U
#define FLYOLOGY_DISCARD_CHUNK 4096U
#define FLYOLOGY_DISCARD_VECTORS \
    ((FLYOLOGY_MAX_IP_DATAGRAM + FLYOLOGY_DISCARD_CHUNK - 1U) / \
     FLYOLOGY_DISCARD_CHUNK)

/* flyology_socket_accept return values below every valid descriptor. */
#define FLYOLOGY_ACCEPT_FAILED (-1)
#define FLYOLOGY_ACCEPT_DISCARDED (-2)

extern int flyology_accept(int socket, void *address, void *length);
extern int flyology_connect(int socket, const void *address, unsigned length);

static int flyology_socket_domain(int family)
{
    return family == 6 ? AF_INET6 : family == 4 ? AF_INET : -1;
}

static int flyology_socket_kind(int mode)
{
    return mode == 2 ? SOCK_DGRAM : mode == 1 ? SOCK_STREAM : -1;
}

static int flyology_socket_configure(int fd, int nonblocking)
{
    int descriptor_flags = fcntl(fd, F_GETFD);
    int status_flags;

    if (descriptor_flags < 0 ||
        fcntl(fd, F_SETFD, descriptor_flags | FD_CLOEXEC) < 0) {
        return -1;
    }

    status_flags = fcntl(fd, F_GETFL);
    if (status_flags < 0 ||
        fcntl(fd, F_SETFL,
              nonblocking ? status_flags | O_NONBLOCK
                          : status_flags & ~O_NONBLOCK) < 0) {
        return -1;
    }

#if defined(SO_NOSIGPIPE)
    {
        int enabled = 1;
        if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE,
                       &enabled, sizeof(enabled)) < 0) {
            return -1;
        }
    }
#endif
    return 0;
}

static int flyology_socket_make_address(
    int family,
    const unsigned char *address,
    unsigned port,
    uint32_t scope,
    struct sockaddr_storage *storage,
    socklen_t *length)
{
    memset(storage, 0, sizeof(*storage));
    if (family == 4) {
        struct sockaddr_in *value = (struct sockaddr_in *)storage;
        value->sin_family = AF_INET;
        value->sin_port = htons((uint16_t)port);
        memcpy(&value->sin_addr, address, 4);
        *length = (socklen_t)sizeof(*value);
        return 0;
    }
    if (family == 6) {
        struct sockaddr_in6 *value = (struct sockaddr_in6 *)storage;
        value->sin6_family = AF_INET6;
        value->sin6_port = htons((uint16_t)port);
        value->sin6_scope_id = scope;
        memcpy(&value->sin6_addr, address, 16);
        *length = (socklen_t)sizeof(*value);
        return 0;
    }
    errno = EAFNOSUPPORT;
    return -1;
}

static int flyology_socket_split_address(
    const struct sockaddr *address,
    socklen_t length,
    unsigned char *family,
    unsigned char *bytes,
    unsigned *port,
    uint32_t *scope)
{
    if (length < (socklen_t)sizeof(address->sa_family)) {
        errno = EINVAL;
        return -1;
    }
    if (address->sa_family == AF_INET) {
        if (length < (socklen_t)sizeof(struct sockaddr_in)) {
            errno = EINVAL;
            return -1;
        }
        const struct sockaddr_in *value =
            (const struct sockaddr_in *)address;
        *family = 4;
        memcpy(bytes, &value->sin_addr, 4);
        memset(bytes + 4, 0, 12);
        *port = ntohs(value->sin_port);
        *scope = 0;
        return 0;
    }
    if (address->sa_family == AF_INET6) {
        if (length < (socklen_t)sizeof(struct sockaddr_in6)) {
            errno = EINVAL;
            return -1;
        }
        const struct sockaddr_in6 *value =
            (const struct sockaddr_in6 *)address;
        *family = 6;
        memcpy(bytes, &value->sin6_addr, 16);
        *port = ntohs(value->sin6_port);
        *scope = value->sin6_scope_id;
        return 0;
    }
    errno = EAFNOSUPPORT;
    return -1;
}

static int flyology_socket_enable_datagram_metadata_impl(int fd)
{
    struct sockaddr_storage storage;
    socklen_t length = (socklen_t)sizeof(storage);
    int enabled = 1;

    if (getsockname(fd, (struct sockaddr *)&storage, &length) < 0) {
        return -1;
    }
    if (storage.ss_family == AF_INET) {
#if defined(IP_PKTINFO)
        if (setsockopt(fd, IPPROTO_IP, IP_PKTINFO,
                       &enabled, sizeof(enabled)) < 0) {
            return -1;
        }
#else
        errno = EAFNOSUPPORT;
        return -1;
#endif
#if defined(IP_RECVTOS)
        if (setsockopt(fd, IPPROTO_IP, IP_RECVTOS,
                       &enabled, sizeof(enabled)) < 0) {
            return -1;
        }
#endif
        return 0;
    }
    if (storage.ss_family == AF_INET6) {
#if defined(IPV6_RECVPKTINFO)
        if (setsockopt(fd, IPPROTO_IPV6, IPV6_RECVPKTINFO,
                       &enabled, sizeof(enabled)) < 0) {
            return -1;
        }
#else
        errno = EAFNOSUPPORT;
        return -1;
#endif
#if defined(IPV6_RECVTCLASS)
        if (setsockopt(fd, IPPROTO_IPV6, IPV6_RECVTCLASS,
                       &enabled, sizeof(enabled)) < 0) {
            return -1;
        }
#endif
        return 0;
    }
    errno = EAFNOSUPPORT;
    return -1;
}

int flyology_socket_errno_would_block(void)
{
    return EWOULDBLOCK;
}

int flyology_socket_errno_interrupted(void)
{
    return EINTR;
}

int flyology_socket_errno_in_progress(void)
{
    return EINPROGRESS;
}

int flyology_socket_errno_already_in_progress(void)
{
    return EALREADY;
}

int flyology_socket_errno_already_connected(void)
{
    return EISCONN;
}

int flyology_socket_errno_no_buffer_space(void)
{
    return ENOBUFS;
}

int flyology_socket_create(int family, int mode, int *error)
{
    int fd = socket(flyology_socket_domain(family),
                    flyology_socket_kind(mode), 0);
    if (fd < 0) {
        *error = errno;
        return -1;
    }
    if (flyology_socket_configure(fd, 0) < 0 ||
        (mode == 2 && flyology_socket_enable_datagram_metadata_impl(fd) < 0)) {
        *error = errno;
        close(fd);
        return -1;
    }
    *error = 0;
    return fd;
}

int flyology_socket_enable_datagram_metadata(int fd, int *error)
{
    if (flyology_socket_enable_datagram_metadata_impl(fd) < 0) {
        *error = errno;
        return -1;
    }
    *error = 0;
    return 0;
}

int flyology_socket_pair(int mode, int *left, int *right, int *error)
{
    int descriptors[2];
    if (socketpair(AF_UNIX, flyology_socket_kind(mode), 0, descriptors) < 0) {
        *error = errno;
        return -1;
    }
    if (flyology_socket_configure(descriptors[0], 0) < 0 ||
        flyology_socket_configure(descriptors[1], 0) < 0) {
        *error = errno;
        close(descriptors[0]);
        close(descriptors[1]);
        return -1;
    }
    *left = descriptors[0];
    *right = descriptors[1];
    *error = 0;
    return 0;
}

int flyology_socket_prepare(int fd, int *error)
{
    if (flyology_socket_configure(fd, 1) < 0) {
        *error = errno;
        return -1;
    }
    *error = 0;
    return 0;
}

int flyology_socket_set_nonblocking(int fd, int enabled, int *error)
{
    if (flyology_socket_configure(fd, enabled != 0) < 0) {
        *error = errno;
        return -1;
    }
    *error = 0;
    return 0;
}

int flyology_socket_close(int fd, int *error)
{
    if (close(fd) < 0) {
        *error = errno;
        return -1;
    }
    *error = 0;
    return 0;
}

int flyology_socket_set_reuse_address(int fd, int enabled, int *error)
{
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR,
                   &enabled, sizeof(enabled)) < 0) {
        *error = errno;
        return -1;
    }
    *error = 0;
    return 0;
}

int flyology_socket_set_receive_timeout(int fd, double seconds, int *error)
{
    struct timeval timeout;
    timeout.tv_sec = (time_t)seconds;
    timeout.tv_usec = (suseconds_t)((seconds - (double)timeout.tv_sec) * 1e6);
    if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO,
                   &timeout, sizeof(timeout)) < 0) {
        *error = errno;
        return -1;
    }
    *error = 0;
    return 0;
}

int flyology_socket_bind(int fd, int family, const unsigned char *address,
                         unsigned port, uint32_t scope, int *error)
{
    struct sockaddr_storage storage;
    socklen_t length;
    if (flyology_socket_make_address(family, address, port, scope,
                                     &storage, &length) < 0 ||
        bind(fd, (struct sockaddr *)&storage, length) < 0) {
        *error = errno;
        return -1;
    }
    *error = 0;
    return 0;
}

int flyology_socket_listen(int fd, int backlog, int *error)
{
    if (listen(fd, backlog) < 0) {
        *error = errno;
        return -1;
    }
    *error = 0;
    return 0;
}

int flyology_socket_name(int fd, int peer, unsigned char *family,
                         unsigned char *address, unsigned *port,
                         uint32_t *scope, int *error)
{
    struct sockaddr_storage storage;
    socklen_t length = (socklen_t)sizeof(storage);
    int result = peer
        ? getpeername(fd, (struct sockaddr *)&storage, &length)
        : getsockname(fd, (struct sockaddr *)&storage, &length);
    if (result < 0 ||
        flyology_socket_split_address((struct sockaddr *)&storage, length,
                                      family, address, port, scope) < 0) {
        *error = errno;
        return -1;
    }
    *error = 0;
    return 0;
}

int flyology_socket_accept(int listener, unsigned char *family,
                           unsigned char *address, unsigned *port,
                           uint32_t *scope, int *error)
{
    struct sockaddr_storage storage;
    socklen_t length = (socklen_t)sizeof(storage);
    int fd = flyology_accept(listener, &storage, &length);
    if (fd < 0) {
        *error = errno;
        return FLYOLOGY_ACCEPT_FAILED;
    }
    if (flyology_socket_split_address((struct sockaddr *)&storage, length,
                                      family, address, port, scope) < 0) {
        int address_error = errno;

        /* An unsupported or malformed peer address indicates that the
           listener does not satisfy the Internet-socket contract. */
        close(fd);
        *error = address_error;
        return FLYOLOGY_ACCEPT_FAILED;
    }
    if (flyology_socket_configure(fd, 1) < 0) {
        int setup_error = errno;

        /* The listener accepted successfully.  A reset peer can make later
           descriptor setup fail (SO_NOSIGPIPE on Darwin and fcntl on either
           platform), so consume this connection without blaming the
           listener. */
        close(fd);
        *error = setup_error;
        return FLYOLOGY_ACCEPT_DISCARDED;
    }
    *error = 0;
    return fd;
}

int flyology_socket_connect(int fd, int family, const unsigned char *address,
                            unsigned port, uint32_t scope, int *error)
{
    struct sockaddr_storage storage;
    socklen_t length;
    if (flyology_socket_make_address(family, address, port, scope,
                                     &storage, &length) < 0 ||
        flyology_connect(fd, &storage, (unsigned)length) < 0) {
        *error = errno;
        return -1;
    }
    *error = 0;
    return 0;
}

int flyology_socket_pending_error(int fd, int *pending, int *error)
{
    socklen_t length = (socklen_t)sizeof(*pending);
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, pending, &length) < 0) {
        *error = errno;
        return -1;
    }
    *error = 0;
    return 0;
}

long flyology_socket_receive(int fd, void *buffer, size_t length, int *error)
{
    ssize_t result = recv(fd, buffer, length, 0);
    *error = result < 0 ? errno : 0;
    return (long)result;
}

long flyology_socket_receive_from(int fd, void *buffer, size_t length,
                                  unsigned char *family,
                                  unsigned char *address, unsigned *port,
                                  uint32_t *scope, int *error)
{
    struct sockaddr_storage storage;
    socklen_t address_length = (socklen_t)sizeof(storage);
    memset(&storage, 0, sizeof(storage));
    *family = 0;
    memset(address, 0, 16);
    *port = 0;
    *scope = 0;
    ssize_t result = recvfrom(fd, buffer, length, 0,
                              (struct sockaddr *)&storage, &address_length);
    if (result < 0) {
        *error = errno;
        return -1;
    }
    if (address_length >= (socklen_t)sizeof(storage.ss_family) &&
        flyology_socket_split_address((struct sockaddr *)&storage,
                                      address_length, family, address, port,
                                      scope) < 0 && errno != EAFNOSUPPORT) {
        *error = errno;
        return -1;
    }
    *error = 0;
    return (long)result;
}

long flyology_socket_receive_datagram(
    int fd, void *buffer, size_t length,
    unsigned char *source_family, unsigned char *source_address,
    unsigned *source_port, uint32_t *source_scope,
    unsigned char *destination_family, unsigned char *destination_address,
    unsigned *destination_port, uint32_t *destination_scope,
    int *ecn, int *error)
{
    struct sockaddr_storage source_storage;
    struct sockaddr_storage local_storage;
    socklen_t local_length = (socklen_t)sizeof(local_storage);
    unsigned char discard[FLYOLOGY_DISCARD_CHUNK];
    struct iovec vectors[1 + FLYOLOGY_DISCARD_VECTORS];
    union {
        struct cmsghdr alignment;
        unsigned char bytes[256];
    } control;
    struct msghdr message;
    struct cmsghdr *header;
    size_t exposed = length < FLYOLOGY_MAX_IP_DATAGRAM
        ? length : FLYOLOGY_MAX_IP_DATAGRAM;
    size_t remaining = FLYOLOGY_MAX_IP_DATAGRAM - exposed;
    size_t vector_count = 0;
    int have_destination = 0;
    ssize_t result;

    memset(&source_storage, 0, sizeof(source_storage));
    memset(&local_storage, 0, sizeof(local_storage));
    memset(&control, 0, sizeof(control));
    memset(&message, 0, sizeof(message));
    *source_family = 0;
    memset(source_address, 0, 16);
    *source_port = 0;
    *source_scope = 0;
    *destination_family = 0;
    memset(destination_address, 0, 16);
    *destination_port = 0;
    *destination_scope = 0;
    *ecn = -1;

    if (exposed > 0) {
        vectors[vector_count].iov_base = buffer;
        vectors[vector_count].iov_len = exposed;
        vector_count++;
    }
    while (remaining > 0) {
        size_t chunk = remaining < sizeof(discard) ? remaining : sizeof(discard);
        /* Reusing this discard area bounds stack use while the iovec lengths
           still let recvmsg report the complete datagram atomically. */
        vectors[vector_count].iov_base = discard;
        vectors[vector_count].iov_len = chunk;
        vector_count++;
        remaining -= chunk;
    }

    message.msg_name = &source_storage;
    message.msg_namelen = (socklen_t)sizeof(source_storage);
    message.msg_iov = vectors;
    message.msg_iovlen = vector_count;
    message.msg_control = control.bytes;
    message.msg_controllen = sizeof(control.bytes);
    result = recvmsg(fd, &message, 0);
    if (result < 0) {
        *error = errno;
        return -1;
    }
    if ((message.msg_flags & (MSG_TRUNC | MSG_CTRUNC)) != 0) {
        *error = EMSGSIZE;
        return -1;
    }
    if (flyology_socket_split_address(
            (struct sockaddr *)&source_storage, message.msg_namelen,
            source_family, source_address, source_port, source_scope) < 0 ||
        getsockname(fd, (struct sockaddr *)&local_storage, &local_length) < 0 ||
        flyology_socket_split_address(
            (struct sockaddr *)&local_storage, local_length,
            destination_family, destination_address,
            destination_port, destination_scope) < 0) {
        *error = errno;
        return -1;
    }

    for (header = CMSG_FIRSTHDR(&message); header != NULL;
         header = CMSG_NXTHDR(&message, header)) {
#if defined(IP_PKTINFO)
        if (header->cmsg_level == IPPROTO_IP &&
            header->cmsg_type == IP_PKTINFO &&
            header->cmsg_len >= CMSG_LEN(sizeof(struct in_pktinfo))) {
            const struct in_pktinfo *info =
                (const struct in_pktinfo *)CMSG_DATA(header);
            *destination_family = 4;
            memcpy(destination_address, &info->ipi_addr, 4);
            memset(destination_address + 4, 0, 12);
            *destination_scope = 0;
            have_destination = 1;
            continue;
        }
#endif
#if defined(IPV6_PKTINFO)
        if (header->cmsg_level == IPPROTO_IPV6 &&
            header->cmsg_type == IPV6_PKTINFO &&
            header->cmsg_len >= CMSG_LEN(sizeof(struct in6_pktinfo))) {
            const struct in6_pktinfo *info =
                (const struct in6_pktinfo *)CMSG_DATA(header);
            *destination_family = 6;
            memcpy(destination_address, &info->ipi6_addr, 16);
            *destination_scope = info->ipi6_ifindex;
            have_destination = 1;
            continue;
        }
#endif
#if defined(IP_RECVTOS)
        if (header->cmsg_level == IPPROTO_IP &&
            (header->cmsg_type == IP_RECVTOS
#if defined(IP_TOS)
             || header->cmsg_type == IP_TOS
#endif
            ) &&
            header->cmsg_len >= CMSG_LEN(sizeof(unsigned char))) {
            *ecn = (*(const unsigned char *)CMSG_DATA(header)) & 0x03;
            continue;
        }
#endif
#if defined(IPV6_TCLASS)
        if (header->cmsg_level == IPPROTO_IPV6 &&
            header->cmsg_type == IPV6_TCLASS &&
            header->cmsg_len >= CMSG_LEN(sizeof(int))) {
            *ecn = (*(const int *)CMSG_DATA(header)) & 0x03;
        }
#endif
    }

    if (!have_destination) {
        *error = EPROTO;
        return -1;
    }
    *error = 0;
    return (long)result;
}

long flyology_socket_send(int fd, const void *buffer, size_t length, int *error)
{
    ssize_t result = send(fd, buffer, length, MSG_NOSIGNAL);
    *error = result < 0 ? errno : 0;
    return (long)result;
}

#if defined(__linux__)
long flyology_linux_guarded_sendfile(int socket_fd, int file_fd,
                                     long long offset, size_t length,
                                     int *error)
{
    if (offset < 0 || length > (size_t)LLONG_MAX) {
        *error = EINVAL;
        return -1;
    }

    struct flyology_sigpipe_guard guard;
    off_t position = (off_t)offset;
    ssize_t result;
    int saved_error;

    if (flyology_sigpipe_begin(&guard) != 0) {
        *error = EIO;
        return -1;
    }
    result = sendfile(socket_fd, file_fd, &position, length);
    saved_error = result < 0 ? errno : 0;
    flyology_sigpipe_end(&guard);
    *error = saved_error;
    return (long)result;
}
#endif

long flyology_socket_send_to(int fd, const void *buffer, size_t length,
                             int family, const unsigned char *address,
                             unsigned port, uint32_t scope, int *error)
{
    struct sockaddr_storage storage;
    socklen_t address_length;
    ssize_t result;
    if (flyology_socket_make_address(family, address, port, scope,
                                     &storage, &address_length) < 0) {
        *error = errno;
        return -1;
    }
    result = sendto(fd, buffer, length, MSG_NOSIGNAL,
                    (struct sockaddr *)&storage, address_length);
    *error = result < 0 ? errno : 0;
    return (long)result;
}

long flyology_socket_send_datagram(
    int fd, const void *buffer, size_t length,
    int destination_family, const unsigned char *destination_address,
    unsigned destination_port, uint32_t destination_scope,
    int select_source, int source_family, const unsigned char *source_address,
    unsigned source_port, uint32_t source_scope, int *error)
{
    struct sockaddr_storage destination_storage;
    struct sockaddr_storage local_storage;
    socklen_t destination_length;
    socklen_t local_length = (socklen_t)sizeof(local_storage);
    unsigned char local_family;
    unsigned char local_address[16];
    unsigned local_port;
    uint32_t local_scope;
    struct iovec vector;
    union {
        struct cmsghdr alignment;
        unsigned char bytes[CMSG_SPACE(sizeof(struct in6_pktinfo))];
    } control;
    struct msghdr message;
    struct cmsghdr *header;
    ssize_t result;

    if (flyology_socket_make_address(
            destination_family, destination_address, destination_port,
            destination_scope, &destination_storage,
            &destination_length) < 0) {
        *error = errno;
        return -1;
    }
    memset(&message, 0, sizeof(message));
    memset(&control, 0, sizeof(control));
    vector.iov_base = (void *)buffer;
    vector.iov_len = length;
    message.msg_name = &destination_storage;
    message.msg_namelen = destination_length;
    message.msg_iov = &vector;
    message.msg_iovlen = 1;

    if (select_source) {
        if (source_family != destination_family) {
            *error = EINVAL;
            return -1;
        }
        if (getsockname(fd, (struct sockaddr *)&local_storage,
                        &local_length) < 0 ||
            flyology_socket_split_address(
                (struct sockaddr *)&local_storage, local_length,
                &local_family, local_address, &local_port, &local_scope) < 0) {
            *error = errno;
            return -1;
        }
        if (local_family != (unsigned char)source_family ||
            local_port != source_port) {
            *error = EINVAL;
            return -1;
        }
        message.msg_control = control.bytes;
        if (source_family == 4) {
#if defined(IP_PKTINFO)
            struct in_pktinfo *info;
            message.msg_controllen = CMSG_SPACE(sizeof(*info));
            header = CMSG_FIRSTHDR(&message);
            header->cmsg_level = IPPROTO_IP;
            header->cmsg_type = IP_PKTINFO;
            header->cmsg_len = CMSG_LEN(sizeof(*info));
            info = (struct in_pktinfo *)CMSG_DATA(header);
            memset(info, 0, sizeof(*info));
            memcpy(&info->ipi_spec_dst, source_address, 4);
#else
            errno = EAFNOSUPPORT;
            *error = errno;
            return -1;
#endif
        } else if (source_family == 6) {
#if defined(IPV6_PKTINFO)
            struct in6_pktinfo *info;
            message.msg_controllen = CMSG_SPACE(sizeof(*info));
            header = CMSG_FIRSTHDR(&message);
            header->cmsg_level = IPPROTO_IPV6;
            header->cmsg_type = IPV6_PKTINFO;
            header->cmsg_len = CMSG_LEN(sizeof(*info));
            info = (struct in6_pktinfo *)CMSG_DATA(header);
            memset(info, 0, sizeof(*info));
            memcpy(&info->ipi6_addr, source_address, 16);
            info->ipi6_ifindex = source_scope;
#else
            errno = EAFNOSUPPORT;
            *error = errno;
            return -1;
#endif
        } else {
            errno = EAFNOSUPPORT;
            *error = errno;
            return -1;
        }
    }

    result = sendmsg(fd, &message, MSG_NOSIGNAL);
    *error = result < 0 ? errno : 0;
    return (long)result;
}

int flyology_socket_bytes_to_read(int fd, unsigned long *count, int *error)
{
    int available;
    if (ioctl(fd, FIONREAD, &available) < 0) {
        *error = errno;
        return -1;
    }
    *count = available < 0 ? 0UL : (unsigned long)available;
    *error = 0;
    return 0;
}

int flyology_socket_parse_address(int family, const char *text,
                                  unsigned char *address)
{
    return inet_pton(flyology_socket_domain(family), text, address);
}

int flyology_socket_image_address(int family, const unsigned char *address,
                                  char *text, unsigned length)
{
    return inet_ntop(flyology_socket_domain(family), address,
                     text, (socklen_t)length) == NULL ? -1 : 0;
}
