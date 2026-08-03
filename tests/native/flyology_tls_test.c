#include <sys/socket.h>

int flyology_test_set_abortive_close(int fd)
{
   struct linger value = { 1, 0 };
   return setsockopt(fd, SOL_SOCKET, SO_LINGER, &value, sizeof value);
}
