#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif
#if defined(__APPLE__) && !defined(__APPLE_USE_RFC_3542)
#define __APPLE_USE_RFC_3542
#endif

#include <netinet/in.h>
#include <sys/socket.h>

/* These test-only leaves use header-defined option numbers, which cannot be
   imported as Ada functions. They change one option each; the Ada smoke test
   owns the ordering and checks the received payload and metadata. */
int flyology_test_datagram_timestamp(int fd, int enabled)
{
    return setsockopt(fd, SOL_SOCKET, SO_TIMESTAMP, &enabled, sizeof(enabled));
}

int flyology_test_datagram_packet_info(int fd, int enabled)
{
    return setsockopt(fd, IPPROTO_IP, IP_PKTINFO, &enabled, sizeof(enabled));
}
