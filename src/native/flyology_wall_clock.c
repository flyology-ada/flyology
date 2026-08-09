#define _POSIX_C_SOURCE 200809L

#include <stdint.h>
#include <errno.h>
#include <stdbool.h>
#include <time.h>

#if defined(__linux__)
#include <sys/timerfd.h>
#elif defined(__APPLE__)
#include <notify.h>
#include <notify_keys.h>
#include <sys/event.h>
#else
#error "Flyology wall-clock waits require Linux or Darwin"
#endif

#if defined(__linux__)
int flyology_wall_clock_clock_realtime(void) { return CLOCK_REALTIME; }
int flyology_wall_clock_timerfd_create_flags(void)
{
    return TFD_CLOEXEC | TFD_NONBLOCK;
}
int flyology_wall_clock_timerfd_settime_flags(void)
{
    return TFD_TIMER_ABSTIME | TFD_TIMER_CANCEL_ON_SET;
}
int flyology_wall_clock_ecanceled(void) { return ECANCELED; }
#elif defined(__APPLE__)
int flyology_wall_clock_clock_realtime(void) { return CLOCK_REALTIME; }
const char *flyology_wall_clock_notify_key(void) { return kNotifyClockSet; }
uint32_t flyology_wall_clock_notify_status_ok(void) { return NOTIFY_STATUS_OK; }
int16_t flyology_wall_clock_evfilt_read(void) { return EVFILT_READ; }
int16_t flyology_wall_clock_evfilt_timer(void) { return EVFILT_TIMER; }
uint16_t flyology_wall_clock_ev_add_enable(void)
{
    return EV_ADD | EV_ENABLE;
}
uint16_t flyology_wall_clock_ev_add_enable_oneshot(void)
{
    return EV_ADD | EV_ENABLE | EV_ONESHOT;
}
uint16_t flyology_wall_clock_ev_error(void) { return EV_ERROR; }
uint32_t flyology_wall_clock_note_nseconds(void) { return NOTE_NSECONDS; }
uint64_t flyology_wall_clock_kevent_size(void) { return sizeof(struct kevent); }
#endif
