/* Focused comparison of Flyology's pathname Unix-socket ABI leaves with the
   host sockaddr_un definition. Policy and socket operations remain in Ada. */

#include <errno.h>
#include <stddef.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>

unsigned flyology_socket_unix_path_max(void);
int flyology_socket_pack_unix_path(const char *, unsigned,
                                   struct sockaddr_storage *, socklen_t *);

int main(void)
{
    static const char pathname[] = "/tmp/flyology.sock";
    static const char with_nul[] = { 'a', '\0', 'b' };
    struct sockaddr_storage storage;
    const struct sockaddr_un *value = (const struct sockaddr_un *)&storage;
    socklen_t length = 0;
    char overlong[sizeof(value->sun_path)];

    if (flyology_socket_unix_path_max() != sizeof(value->sun_path) - 1U)
        return 1;
    if (flyology_socket_pack_unix_path(
          pathname, (unsigned)(sizeof(pathname) - 1U), &storage, &length) != 0)
        return 2;
    if (value->sun_family != AF_UNIX ||
        memcmp(value->sun_path, pathname, sizeof(pathname)) != 0 ||
        length != (socklen_t)(offsetof(struct sockaddr_un, sun_path) +
                             sizeof(pathname)))
        return 3;
#if defined(__APPLE__)
    if (value->sun_len != (unsigned char)length)
        return 4;
#endif

    memset(overlong, 'x', sizeof(overlong));
    errno = 0;
    if (flyology_socket_pack_unix_path(
          overlong, (unsigned)sizeof(overlong), &storage, &length) != -1 ||
        errno != ENAMETOOLONG)
        return 5;
    errno = 0;
    if (flyology_socket_pack_unix_path(
          with_nul, (unsigned)sizeof(with_nul), &storage, &length) != -1 ||
        errno != EINVAL)
        return 6;
    return 0;
}
