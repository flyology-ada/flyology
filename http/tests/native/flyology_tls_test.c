#include <sys/socket.h>

#include "flyology_tls_signal.h"

static int sigwait_calls;

static int interrupted_sigwait
  (const sigset_t *set, siginfo_t *info, const struct timespec *timeout)
{
   (void)set;
   (void)info;
   (void)timeout;
   sigwait_calls++;
   if (sigwait_calls < 3) {
      errno = EINTR;
      return -1;
   }
   return SIGPIPE;
}

static int unavailable_sigwait
  (const sigset_t *set, siginfo_t *info, const struct timespec *timeout)
{
   (void)set;
   (void)info;
   (void)timeout;
   sigwait_calls++;
   errno = EAGAIN;
   return -1;
}

int flyology_test_set_abortive_close(int fd)
{
   struct linger value = { 1, 0 };
   return setsockopt(fd, SOL_SOCKET, SO_LINGER, &value, sizeof value);
}

int flyology_test_sigtimedwait_retry(void)
{
   sigset_t set;
   const struct timespec no_wait = { 0, 0 };

   if (sigemptyset(&set) != 0 || sigaddset(&set, SIGPIPE) != 0)
      return 0;
   sigwait_calls = 0;
   if (flyology_sigtimedwait_retry
         (&set, &no_wait, interrupted_sigwait) != SIGPIPE ||
       sigwait_calls != 3)
      return 0;
   sigwait_calls = 0;
   if (flyology_sigtimedwait_retry
         (&set, &no_wait, unavailable_sigwait) != -1 ||
       errno != EAGAIN || sigwait_calls != 1)
      return 0;
   return 1;
}
