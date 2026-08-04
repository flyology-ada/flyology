#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <time.h>
#include <unistd.h>

#if defined(__linux__)
#include <sys/timerfd.h>
#elif defined(__APPLE__)
#include <notify.h>
#include <notify_keys.h>
#include <sys/event.h>
#else
#error "Flyology wall-clock waits require Linux or Darwin"
#endif

struct flyology_wall_wait_state {
    int wait_fd;
    int change_fd;
    int token;
};

static void add_nanoseconds(struct timespec *value, int64_t nanoseconds)
{
    value->tv_sec += (time_t)(nanoseconds / INT64_C(1000000000));
    value->tv_nsec += (long)(nanoseconds % INT64_C(1000000000));
    if (value->tv_nsec >= 1000000000L) {
        value->tv_sec += 1;
        value->tv_nsec -= 1000000000L;
    }
}

static bool timespec_before(
    const struct timespec *left, const struct timespec *right)
{
    return left->tv_sec < right->tv_sec ||
        (left->tv_sec == right->tv_sec && left->tv_nsec < right->tv_nsec);
}

#if defined(__APPLE__)
static int64_t timespec_difference_nanoseconds(
    const struct timespec *later, const struct timespec *earlier)
{
    int64_t seconds = (int64_t)(later->tv_sec - earlier->tv_sec);
    return seconds * INT64_C(1000000000) + later->tv_nsec - earlier->tv_nsec;
}
#endif

/* Convert a proleptic Gregorian civil date to days since 1970-01-01. The
   supported Ada.Calendar range is small enough for every intermediate. */
static int64_t days_from_civil(int year, unsigned month, unsigned day)
{
    year -= month <= 2;
    int era = (year >= 0 ? year : year - 399) / 400;
    unsigned year_of_era = (unsigned)(year - era * 400);
    unsigned adjusted_month = month > 2 ? month - 3 : month + 9;
    unsigned day_of_year =
        (153 * adjusted_month + 2) / 5 + day - 1;
    unsigned day_of_era =
        year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    return (int64_t)era * 146097 + day_of_era - 719468;
}

int flyology_wall_wait_open(struct flyology_wall_wait_state *state)
{
    state->wait_fd = -1;
    state->change_fd = -1;
    state->token = -1;

#if defined(__linux__)
    state->wait_fd =
        timerfd_create(CLOCK_REALTIME, TFD_CLOEXEC | TFD_NONBLOCK);
    state->change_fd = state->wait_fd;
    return state->wait_fd < 0 ? -1 : 0;
#elif defined(__APPLE__)
    struct kevent change;
    uint32_t status;

    state->wait_fd = kqueue();
    if (state->wait_fd < 0) {
        return -1;
    }
    status = notify_register_file_descriptor(
        kNotifyClockSet, &state->change_fd, 0, &state->token);
    if (status != NOTIFY_STATUS_OK) {
        state->change_fd = -1;
        state->token = -1;
        return 0;
    }

    EV_SET(&change, (uintptr_t)state->change_fd, EVFILT_READ,
           EV_ADD | EV_ENABLE, 0, 0, NULL);
    if (kevent(state->wait_fd, &change, 1, NULL, 0, NULL) < 0) {
        notify_cancel(state->token);
        state->change_fd = -1;
        state->token = -1;
        return 0;
    }
    return 0;
#endif
}

int flyology_wall_wait_arm(
    struct flyology_wall_wait_state *state,
    int target_year,
    int target_month,
    int target_day,
    int target_hour,
    int target_minute,
    int target_second,
    long target_nanoseconds,
    int target_is_leap_second,
    int64_t maximum_slice_nanoseconds)
{
    struct timespec now;
    int64_t target_seconds;
    struct timespec target;
    struct timespec probe;
    struct timespec deadline;

    if (state->wait_fd < 0 || target_year < 1901 || target_year > 2399 ||
        target_month < 1 || target_month > 12 ||
        target_day < 1 || target_day > 31 ||
        target_hour < 0 || target_hour > 23 ||
        target_minute < 0 || target_minute > 59 ||
        target_second < 0 || target_second > 59 ||
        (target_is_leap_second != 0 && target_is_leap_second != 1) ||
        target_nanoseconds < 0 ||
        target_nanoseconds >= 1000000000L || maximum_slice_nanoseconds <= 0 ||
        clock_gettime(CLOCK_REALTIME, &now) != 0) {
        errno = EINVAL;
        return -1;
    }
    target_seconds =
        days_from_civil(target_year, (unsigned)target_month,
                        (unsigned)target_day) * INT64_C(86400) +
        target_hour * INT64_C(3600) + target_minute * INT64_C(60) +
        target_second + target_is_leap_second;
    target.tv_sec = (time_t)target_seconds;
    target.tv_nsec = target_nanoseconds;
    if ((int64_t)target.tv_sec != target_seconds) {
        errno = EOVERFLOW;
        return -1;
    }
    probe = now;
    add_nanoseconds(&probe, maximum_slice_nanoseconds);
    deadline = timespec_before(&target, &probe) ? target : probe;

#if defined(__linux__)
    struct itimerspec timer = {0};
    timer.it_value = deadline;
    if (timerfd_settime(state->wait_fd,
                        TFD_TIMER_ABSTIME | TFD_TIMER_CANCEL_ON_SET,
                        &timer, NULL) == 0) {
        return 0;
    }
    /* Linux rearms the timer even when it reports a clock cancellation left
       unread from a race with the preceding consume. */
    return errno == ECANCELED ? 1 : -1;
#elif defined(__APPLE__)
    struct kevent timer;
    if (state->change_fd >= 0) {
        int64_t target_microseconds =
            (int64_t)deadline.tv_sec * INT64_C(1000000) +
            deadline.tv_nsec / 1000;
        EV_SET(&timer, 1, EVFILT_TIMER, EV_ADD | EV_ENABLE | EV_ONESHOT,
               NOTE_ABSOLUTE | NOTE_USECONDS, target_microseconds, NULL);
    } else {
        int64_t timeout_nanoseconds =
            timespec_difference_nanoseconds(&deadline, &now);
        /* A monotonic probe bounds backstep detection when notifyd is absent.
           A target crossed during setup becomes an immediate one-nanosecond
           probe and is classified by the caller's post-arm sample. */
        if (timeout_nanoseconds <= 0) {
            timeout_nanoseconds = 1;
        }
        EV_SET(&timer, 1, EVFILT_TIMER, EV_ADD | EV_ENABLE | EV_ONESHOT,
               NOTE_NSECONDS, timeout_nanoseconds, NULL);
    }
    return kevent(state->wait_fd, &timer, 1, NULL, 0, NULL) < 0 ? -1 : 0;
#endif
}

int flyology_wall_wait_consume(struct flyology_wall_wait_state *state)
{
#if defined(__linux__)
    uint64_t expirations;
    ssize_t result;

    do {
        result = read(state->wait_fd, &expirations, sizeof(expirations));
    } while (result < 0 && errno == EINTR);
    if (result == (ssize_t)sizeof(expirations)) {
        return 0;
    }
    return result < 0 && errno == ECANCELED ? 1 : -1;
#elif defined(__APPLE__)
    struct kevent event;
    struct timespec zero = {0, 0};
    int result = kevent(state->wait_fd, NULL, 0, &event, 1, &zero);

    if (result != 1) {
        if (result == 0) {
            errno = EAGAIN;
        }
        return -1;
    }
    if ((event.flags & EV_ERROR) != 0) {
        errno = (int)event.data;
        return -1;
    }
    if (event.filter == EVFILT_TIMER) {
        return 0;
    }
    if (event.filter == EVFILT_READ &&
        event.ident == (uintptr_t)state->change_fd) {
        int delivered_token;
        ssize_t bytes;
        do {
            bytes = read(state->change_fd, &delivered_token,
                         sizeof(delivered_token));
        } while (bytes < 0 && errno == EINTR);
        return bytes == (ssize_t)sizeof(delivered_token) ? 1 : -1;
    }
    errno = EIO;
    return -1;
#endif
}

void flyology_wall_wait_close(struct flyology_wall_wait_state *state)
{
#if defined(__linux__)
    if (state->wait_fd >= 0) {
        close(state->wait_fd);
    }
#elif defined(__APPLE__)
    if (state->token >= 0) {
        notify_cancel(state->token);
    }
    if (state->wait_fd >= 0) {
        close(state->wait_fd);
    }
#endif
    state->wait_fd = -1;
    state->change_fd = -1;
    state->token = -1;
}
