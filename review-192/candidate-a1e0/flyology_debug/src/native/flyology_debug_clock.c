/* Copyright (c) 2026 Yurii Rashkovskii
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <time.h>

#if defined(__APPLE__)
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <pthread.h>

static mach_timebase_info_data_t flyology_debug_timebase;
static kern_return_t flyology_debug_timebase_status;
static pthread_once_t flyology_debug_timebase_once = PTHREAD_ONCE_INIT;

static void flyology_debug_initialize_timebase(void)
{
    flyology_debug_timebase_status =
        mach_timebase_info(&flyology_debug_timebase);
}
#elif !defined(__linux__)
#error "flyology_debug clock supports Darwin and Linux"
#endif

int flyology_debug_clock_now(uint64_t *nanoseconds)
{
    if (nanoseconds == NULL) {
        errno = EINVAL;
        return -1;
    }

#if defined(__APPLE__)
    __uint128_t converted;

    if (pthread_once(&flyology_debug_timebase_once,
                     flyology_debug_initialize_timebase) != 0
        || flyology_debug_timebase_status != KERN_SUCCESS
        || flyology_debug_timebase.denom == 0) {
        errno = EIO;
        return -1;
    }

    converted = (__uint128_t)mach_absolute_time()
        * flyology_debug_timebase.numer;
    converted /= flyology_debug_timebase.denom;
    if (converted > UINT64_MAX) {
        errno = EOVERFLOW;
        return -1;
    }
    *nanoseconds = (uint64_t)converted;
    return 0;
#else
    struct timespec value;

    if (clock_gettime(CLOCK_MONOTONIC_RAW, &value) != 0) {
        return -1;
    }
    if (value.tv_sec < 0
        || value.tv_nsec < 0
        || value.tv_nsec >= 1000000000L
        || (uint64_t)value.tv_sec > UINT64_MAX / UINT64_C(1000000000)
        || ((uint64_t)value.tv_sec
                == UINT64_MAX / UINT64_C(1000000000)
            && (uint64_t)value.tv_nsec
                > UINT64_MAX % UINT64_C(1000000000))) {
        errno = EOVERFLOW;
        return -1;
    }
    *nanoseconds = (uint64_t)value.tv_sec * UINT64_C(1000000000)
        + (uint64_t)value.tv_nsec;
    return 0;
#endif
}
