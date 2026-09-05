/* Copyright (c) 2026 Yurii Rashkovskii
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */

/* Leaf platform values and mechanisms for flyology_bench.
 *
 * Everything this crate measures is decided in Ada. This file holds only the
 * three things Ada cannot reach on its own:
 *
 *   1. Preprocessor constants (open and flock flags, clock identifiers,
 *      system-call numbers, perf ioctl requests, limits, storage sizes).
 *   2. Entry points that exist on one platform only, so a single Ada body
 *      importing them directly would not link on the other. Each is a bare
 *      call with no retry, classification, or bookkeeping of its own.
 *   3. Registration of a thread-exit callback, which POSIX exposes only
 *      through pthread_key_create and a key type with no portable Ada
 *      representation.
 *
 * The stubs a platform does not implement report ENOSYS. Ada never calls
 * them there: it selects by flyology_bench_platform_os and takes its own
 * path, so the stubs exist for linking rather than for use.
 */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/file.h>
#include <sys/resource.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/processor_info.h>
#include <mach/thread_policy.h>
#elif defined(__linux__)
#include <linux/perf_event.h>
#include <sched.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#else
#error "flyology_bench supports Darwin and Linux"
#endif

/* GCC 13 through 15 do not expose SIZEOF_tv_nsec in System.OS_Constants.
 * Ada therefore derives the field width from Interfaces.C.long. Fail the
 * build if a supported target's headers give timespec.tv_nsec another type.
 */
_Static_assert(
    _Generic(((struct timespec *)0)->tv_nsec, long: 1, default: 0),
    "struct timespec.tv_nsec must have C long type");

/* ------------------------------------------------------------------ */
/* Platform identity.                                                  */
/* ------------------------------------------------------------------ */

#if defined(__APPLE__)
const int flyology_bench_platform_os = 1;
#else
const int flyology_bench_platform_os = 2;
#endif

#if defined(__aarch64__) || defined(__arm64__)
const int flyology_bench_platform_architecture = 1;
#elif defined(__x86_64__)
const int flyology_bench_platform_architecture = 2;
#else
const int flyology_bench_platform_architecture = 0;
#endif

/* ------------------------------------------------------------------ */
/* Header constants.                                                   */
/* ------------------------------------------------------------------ */

const int flyology_bench_o_rdwr = O_RDWR;
const int flyology_bench_o_creat = O_CREAT;
const int flyology_bench_o_cloexec = O_CLOEXEC;
const int flyology_bench_o_nofollow = O_NOFOLLOW;

const int flyology_bench_lock_shared = LOCK_SH;
const int flyology_bench_lock_exclusive = LOCK_EX;
const int flyology_bench_lock_nonblocking = LOCK_NB;
const int flyology_bench_lock_unlock = LOCK_UN;

const int flyology_bench_sc_pagesize = _SC_PAGESIZE;

/* The first logical CPU number the placement call cannot name. Darwin's
 * affinity tag is an int; Linux bounds the mask by CPU_SETSIZE.
 */
#if defined(__APPLE__)
const int flyology_bench_cpu_limit = INT_MAX;
#else
const int flyology_bench_cpu_limit = CPU_SETSIZE;
#endif

/* Linux counts monotonic nanoseconds through clock_gettime; Darwin reads
 * Mach ticks instead, so it publishes no clock identifier.
 */
#if defined(__APPLE__)
const int flyology_bench_monotonic_clock = -1;
#else
const int flyology_bench_monotonic_clock = CLOCK_MONOTONIC_RAW;
#endif

#if defined(__linux__)
const long flyology_bench_perf_event_open_call = __NR_perf_event_open;
const unsigned long flyology_bench_perf_enable_request = PERF_EVENT_IOC_ENABLE;
const unsigned long flyology_bench_perf_disable_request =
    PERF_EVENT_IOC_DISABLE;
const unsigned long flyology_bench_perf_group_flag = PERF_IOC_FLAG_GROUP;
#else
const long flyology_bench_perf_event_open_call = 0;
const unsigned long flyology_bench_perf_enable_request = 0;
const unsigned long flyology_bench_perf_disable_request = 0;
const unsigned long flyology_bench_perf_group_flag = 0;
#endif

/* Ada reserves its own aligned storage for the recorder registry lock and
 * checks it against this before initializing the mutex in place.
 */
const size_t flyology_bench_pthread_mutex_size = sizeof(pthread_mutex_t);

/* Ada declares the time and resource-usage structures itself, from the
 * field widths the compiler's own platform specification records. These
 * let it check the result against the headers during elaboration rather
 * than trusting the derivation.
 */
const size_t flyology_bench_timeval_bytes = sizeof(struct timeval);
const size_t flyology_bench_timespec_bytes = sizeof(struct timespec);
const size_t flyology_bench_rusage_bytes = sizeof(struct rusage);
const size_t flyology_bench_rusage_counters_offset =
    offsetof(struct rusage, ru_maxrss);

/* ------------------------------------------------------------------ */
/* Monotonic clock.                                                    */
/* ------------------------------------------------------------------ */

uint64_t flyology_bench_mach_ticks(void)
{
#if defined(__APPLE__)
    return mach_absolute_time();
#else
    return 0;
#endif
}

int flyology_bench_mach_timebase(uint32_t *numerator, uint32_t *denominator)
{
#if defined(__APPLE__)
    mach_timebase_info_data_t timebase;

    if (mach_timebase_info(&timebase) != KERN_SUCCESS) {
        errno = EIO;
        return -1;
    }
    *numerator = timebase.numer;
    *denominator = timebase.denom;
    return 0;
#else
    (void)numerator;
    (void)denominator;
    errno = ENOSYS;
    return -1;
#endif
}

/* ------------------------------------------------------------------ */
/* Thread identity and placement.                                      */
/* ------------------------------------------------------------------ */

uint64_t flyology_bench_native_thread_id(void)
{
#if defined(__APPLE__)
    uint64_t identifier = 0;

    if (pthread_threadid_np(NULL, &identifier) != 0) {
        return 0;
    }
    return identifier;
#else
    return (uint64_t)syscall(__NR_gettid);
#endif
}

/* Binds the calling thread to one logical CPU. The caller has already
 * rejected CPU numbers above flyology_bench_cpu_limit.
 */
int flyology_bench_bind_thread(unsigned int cpu)
{
#if defined(__APPLE__)
    thread_affinity_policy_data_t policy = {(integer_t) (cpu + 1)};
    thread_port_t thread = mach_thread_self();
    kern_return_t status = thread_policy_set(
        thread, THREAD_AFFINITY_POLICY,
        (thread_policy_t)&policy, THREAD_AFFINITY_POLICY_COUNT);

    (void)mach_port_deallocate(mach_task_self(), thread);
    if (status != KERN_SUCCESS) {
        errno = EINVAL;
        return -1;
    }
    return 0;
#else
    cpu_set_t set;
    int status;

    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    status = pthread_setaffinity_np(pthread_self(), sizeof(set), &set);
    if (status != 0) {
        errno = status;
        return -1;
    }
    return 0;
#endif
}

/* ------------------------------------------------------------------ */
/* Telemetry only the Mach interfaces publish.                          */
/*                                                                     */
/* Linux answers the same three questions from /proc, which Ada reads   */
/* directly, so these carry a stub there.                               */
/* ------------------------------------------------------------------ */

int flyology_bench_mach_resident_bytes(uint64_t *bytes)
{
#if defined(__APPLE__)
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;

    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                  (task_info_t)&info, &count) != KERN_SUCCESS) {
        errno = EIO;
        return -1;
    }
    *bytes = (uint64_t)info.resident_size;
    return 0;
#else
    (void)bytes;
    errno = ENOSYS;
    return -1;
#endif
}

int flyology_bench_mach_disk_io(uint64_t *read_bytes, uint64_t *written_bytes)
{
#if defined(__APPLE__)
    struct rusage_info_v2 info;

    if (proc_pid_rusage(getpid(), RUSAGE_INFO_V2,
                        (rusage_info_t *)&info) != 0) {
        return -1;
    }
    *read_bytes = info.ri_diskio_bytesread;
    *written_bytes = info.ri_diskio_byteswritten;
    return 0;
#else
    (void)read_bytes;
    (void)written_bytes;
    errno = ENOSYS;
    return -1;
#endif
}

/* Per-CPU busy and total tick totals. host_processor_info hands back an
 * allocation that only vm_deallocate can release, so the whole exchange
 * stays on this side of the boundary.
 */
int flyology_bench_mach_cpu_ticks(uint64_t *busy_ticks,
                                  uint64_t *total_ticks,
                                  size_t capacity,
                                  size_t *cpu_count)
{
#if defined(__APPLE__)
    host_t host = mach_host_self();
    natural_t count = 0;
    processor_info_array_t raw_info = NULL;
    mach_msg_type_number_t raw_count = 0;
    kern_return_t status = host_processor_info(
        host, PROCESSOR_CPU_LOAD_INFO, &count, &raw_info, &raw_count);
    processor_cpu_load_info_t load_info;

    if (status != KERN_SUCCESS) {
        (void)mach_port_deallocate(mach_task_self(), host);
        errno = EIO;
        return -1;
    }
    if ((size_t)count > capacity) {
        (void)vm_deallocate(mach_task_self(), (vm_address_t)raw_info,
                            (vm_size_t)raw_count * sizeof(integer_t));
        (void)mach_port_deallocate(mach_task_self(), host);
        errno = ENOSPC;
        return -1;
    }
    load_info = (processor_cpu_load_info_t)raw_info;
    for (natural_t cpu = 0; cpu < count; ++cpu) {
        uint64_t user = load_info[cpu].cpu_ticks[CPU_STATE_USER];
        uint64_t system = load_info[cpu].cpu_ticks[CPU_STATE_SYSTEM];
        uint64_t nice = load_info[cpu].cpu_ticks[CPU_STATE_NICE];
        uint64_t idle = load_info[cpu].cpu_ticks[CPU_STATE_IDLE];

        busy_ticks[cpu] = user + system + nice;
        total_ticks[cpu] = busy_ticks[cpu] + idle;
    }
    *cpu_count = (size_t)count;
    (void)vm_deallocate(mach_task_self(), (vm_address_t)raw_info,
                        (vm_size_t)raw_count * sizeof(integer_t));
    (void)mach_port_deallocate(mach_task_self(), host);
    return 0;
#else
    (void)busy_ticks;
    (void)total_ticks;
    (void)capacity;
    (void)cpu_count;
    errno = ENOSYS;
    return -1;
#endif
}

/* ------------------------------------------------------------------ */
/* Per-thread token with an exit callback.                             */
/*                                                                     */
/* pthread_key_create is the only POSIX way to run work when a thread   */
/* ends, and pthread_key_t is an integer whose width differs by         */
/* platform, so the key stays here. The token is opaque: what it owns   */
/* and what releasing it means are decided in Ada.                      */
/* ------------------------------------------------------------------ */

/* The callback lives in the token rather than in a shared variable, so it
 * is written once by the thread that owns it and read only by that thread's
 * destructor.
 */
struct flyology_bench_thread_entry {
    void (*at_exit)(void *);
};

static pthread_key_t flyology_bench_thread_key;
static pthread_once_t flyology_bench_thread_key_once = PTHREAD_ONCE_INIT;
static int flyology_bench_thread_key_status = -1;

static void flyology_bench_thread_key_destroy(void *token)
{
    struct flyology_bench_thread_entry *entry = token;

    if (entry->at_exit != NULL) {
        entry->at_exit(token);
    }
    free(entry);
}

static void flyology_bench_thread_key_initialize(void)
{
    flyology_bench_thread_key_status = pthread_key_create(
        &flyology_bench_thread_key, flyology_bench_thread_key_destroy);
}

/* Returns this thread's token, creating it on first use and arranging for
 * at_exit to run with it when the thread ends. Later calls on the same
 * thread return the same token. Returns NULL with errno set on failure.
 */
void *flyology_bench_thread_token(void (*at_exit)(void *))
{
    struct flyology_bench_thread_entry *entry;
    int status = pthread_once(&flyology_bench_thread_key_once,
                              flyology_bench_thread_key_initialize);

    if (status != 0 || flyology_bench_thread_key_status != 0) {
        errno = status != 0 ? status : flyology_bench_thread_key_status;
        return NULL;
    }
    entry = pthread_getspecific(flyology_bench_thread_key);
    if (entry == NULL) {
        entry = calloc(1, sizeof(*entry));
        if (entry == NULL) {
            return NULL;
        }
        entry->at_exit = at_exit;
        status = pthread_setspecific(flyology_bench_thread_key, entry);
        if (status != 0) {
            free(entry);
            errno = status;
            return NULL;
        }
    }
    return entry;
}
