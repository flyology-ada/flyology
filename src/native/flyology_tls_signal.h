#ifndef FLYOLOGY_TLS_SIGNAL_H
#define FLYOLOGY_TLS_SIGNAL_H

#include <errno.h>
#include <signal.h>
#include <time.h>

typedef int (*flyology_sigtimedwait_fn)
  (const sigset_t *, siginfo_t *, const struct timespec *);

/* A zero-time signal dequeue remains an immediate poll after interruption.
 * The caller decides which successful signal and terminal errno are valid. */
static inline int flyology_sigtimedwait_retry
  (const sigset_t *set,
   const struct timespec *timeout,
   flyology_sigtimedwait_fn wait_fn)
{
   int result;
   do {
      result = wait_fn(set, NULL, timeout);
   } while (result < 0 && errno == EINTR);
   return result;
}

#endif
