#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
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
