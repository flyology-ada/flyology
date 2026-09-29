#ifndef FLYOLOGY_TLS_SIGNAL_H
#define FLYOLOGY_TLS_SIGNAL_H

#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
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

/* Linux has no per-socket SO_NOSIGPIPE equivalent. Calls without a
 * MSG_NOSIGNAL argument use this guard only while they execute synchronously
 * on one pthread: retain a signal that was pending before the call, consume
 * one newly generated SIGPIPE, and restore the exact prior mask. */
struct flyology_sigpipe_guard {
#if !defined(__APPLE__)
   sigset_t set;
   sigset_t old_mask;
   int pending_before;
   int active;
#else
   int unused;
#endif
};

static inline int flyology_sigpipe_begin
  (struct flyology_sigpipe_guard *guard)
{
#if !defined(__APPLE__)
   sigset_t pending;
   int member;
   memset(guard, 0, sizeof *guard);
   if (sigemptyset(&guard->set) != 0 ||
       sigaddset(&guard->set, SIGPIPE) != 0)
      return -1;
   if (pthread_sigmask(SIG_BLOCK, &guard->set, &guard->old_mask) != 0)
      return -1;
   guard->active = 1;
   if (sigpending(&pending) != 0) {
      if (pthread_sigmask(SIG_SETMASK, &guard->old_mask, NULL) != 0) abort();
      guard->active = 0;
      return -1;
   }
   member = sigismember(&pending, SIGPIPE);
   if (member < 0) {
      if (pthread_sigmask(SIG_SETMASK, &guard->old_mask, NULL) != 0) abort();
      guard->active = 0;
      return -1;
   }
   guard->pending_before = member == 1;
#else
   (void)guard;
#endif
   return 0;
}

static inline void flyology_sigpipe_end
  (struct flyology_sigpipe_guard *guard)
{
#if !defined(__APPLE__)
   sigset_t pending;
   int member;
   if (!guard->active) return;
   if (sigpending(&pending) != 0) abort();
   member = sigismember(&pending, SIGPIPE);
   if (member < 0) abort();
   if (!guard->pending_before && member == 1) {
      struct timespec no_wait = { 0, 0 };
      if (flyology_sigtimedwait_retry
            (&guard->set, &no_wait, sigtimedwait) != SIGPIPE)
         abort();
   }
   if (pthread_sigmask(SIG_SETMASK, &guard->old_mask, NULL) != 0) abort();
#else
   (void)guard;
#endif
}

#endif
