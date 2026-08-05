#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdint.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#if !defined(MSG_NOSIGNAL)
#define MSG_NOSIGNAL 0
#endif

extern int flyology_accept(int socket, void *address, void *length);

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
    if (flyology_socket_configure(fd, 0) < 0) {
        *error = errno;
        close(fd);
        return -1;
    }
    *error = 0;
    return fd;
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
        return -1;
    }
    if (flyology_socket_configure(fd, 1) < 0 ||
        flyology_socket_split_address((struct sockaddr *)&storage, length,
                                      family, address, port, scope) < 0) {
        *error = errno;
        close(fd);
        return -1;
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
        connect(fd, (struct sockaddr *)&storage, length) < 0) {
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

long flyology_socket_send(int fd, const void *buffer, size_t length, int *error)
{
    ssize_t result = send(fd, buffer, length, MSG_NOSIGNAL);
    *error = result < 0 ? errno : 0;
    return (long)result;
}

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
