#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

/* Queue reset IPv4 connections before the structured server begins accepting.
 * Each client descriptor is closed before the next iteration so the caller
 * can verify that neither side leaks descriptors. */
int flyology_test_queue_tcp_resets(unsigned port, unsigned count)
{
    struct sockaddr_in address;
    struct linger reset = {1, 0};

    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons((uint16_t)port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    for (unsigned index = 0; index < count; ++index) {
        int fd = socket(AF_INET, SOCK_STREAM, 0);

        if (fd < 0) {
            return errno;
        }
        if (setsockopt(fd, SOL_SOCKET, SO_LINGER,
                       &reset, sizeof(reset)) < 0 ||
            connect(fd, (const struct sockaddr *)&address,
                    (socklen_t)sizeof(address)) < 0) {
            int error = errno;

            close(fd);
            return error;
        }
        if (close(fd) < 0) {
            return errno;
        }
    }
    return 0;
}

/* Return an AF_UNIX listener with one queued client so the Ada accept path can
 * verify that unsupported peer addresses remain structural failures. */
int flyology_test_unix_listener(int *error)
{
    char path[] = "/tmp/flyology-accept-XXXXXX";
    struct sockaddr_un address;
    int placeholder = -1;
    int listener = -1;
    int client = -1;

    placeholder = mkstemp(path);
    if (placeholder < 0) {
        goto fail;
    }
    if (close(placeholder) < 0) {
        placeholder = -1;
        goto fail;
    }
    placeholder = -1;
    if (unlink(path) < 0) {
        goto fail;
    }

    listener = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listener < 0) {
        goto fail;
    }
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    memcpy(address.sun_path, path, sizeof(path));
    if (bind(listener, (const struct sockaddr *)&address,
             (socklen_t)sizeof(address)) < 0 ||
        listen(listener, 1) < 0) {
        goto fail;
    }

    client = socket(AF_UNIX, SOCK_STREAM, 0);
    if (client < 0 ||
        connect(client, (const struct sockaddr *)&address,
                (socklen_t)sizeof(address)) < 0) {
        goto fail;
    }
    if (close(client) < 0) {
        client = -1;
        goto fail;
    }
    client = -1;
    if (unlink(path) < 0) {
        goto fail;
    }
    *error = 0;
    return listener;

fail:
    {
        int saved_error = errno;

        if (placeholder >= 0) {
            close(placeholder);
        }
        if (client >= 0) {
            close(client);
        }
        if (listener >= 0) {
            close(listener);
        }
        unlink(path);
        *error = saved_error;
        return -1;
    }
}
