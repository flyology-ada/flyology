/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include <errno.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>

int flyology_monotonic_clock(struct timespec *value);
int flyology_monotonic_resolution(struct timespec *value);
int flyology_darwin_cond_timedwait_relative(
    pthread_cond_t *condition,
    pthread_mutex_t *mutex,
    const struct timespec *timeout);

static uint64_t timespec_nanoseconds(const struct timespec *value)
{
    return (uint64_t)value->tv_sec * UINT64_C(1000000000) +
        (uint64_t)value->tv_nsec;
}

static uint64_t mach_nanoseconds(uint64_t ticks)
{
    mach_timebase_info_data_t timebase;
    __uint128_t value;

    if (mach_timebase_info(&timebase) != KERN_SUCCESS || timebase.denom == 0) {
        return UINT64_MAX;
    }
    value = (__uint128_t)ticks * timebase.numer / timebase.denom;
    return value > UINT64_MAX ? UINT64_MAX : (uint64_t)value;
}

int main(void)
{
    pthread_cond_t condition = PTHREAD_COND_INITIALIZER;
    pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
    const struct timespec timeout = {0, 5000000L};
    struct timespec sample;
    struct timespec resolution;
    struct timespec started;
    struct timespec finished;
    uint64_t before = mach_absolute_time();
    uint64_t after;
    int result;

    if (flyology_monotonic_clock(&sample) != 0) {
        perror("flyology_monotonic_clock");
        return 1;
    }
    after = mach_absolute_time();
    if (timespec_nanoseconds(&sample) < mach_nanoseconds(before) ||
        timespec_nanoseconds(&sample) > mach_nanoseconds(after)) {
        fputs("monotonic sample is outside its Mach absolute bracket\n", stderr);
        return 1;
    }
    if (flyology_monotonic_resolution(&resolution) != 0 ||
        resolution.tv_sec != 0 || resolution.tv_nsec <= 0) {
        fputs("invalid monotonic resolution\n", stderr);
        return 1;
    }

    if (pthread_mutex_lock(&mutex) != 0 ||
        flyology_monotonic_clock(&started) != 0) {
        fputs("cannot begin relative wait probe\n", stderr);
        return 1;
    }
    result = flyology_darwin_cond_timedwait_relative(
        &condition, &mutex, &timeout);
    if (flyology_monotonic_clock(&finished) != 0 ||
        pthread_mutex_unlock(&mutex) != 0) {
        fputs("cannot finish relative wait probe\n", stderr);
        return 1;
    }
    if (result != ETIMEDOUT ||
        timespec_nanoseconds(&finished) < timespec_nanoseconds(&started) ||
        timespec_nanoseconds(&finished) - timespec_nanoseconds(&started) <
            UINT64_C(5000000)) {
        fputs("relative pthread wait does not match the monotonic source\n",
              stderr);
        return 1;
    }
    return 0;
}
