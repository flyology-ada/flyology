/* Copyright (c) 2026 Yurii Rashkovskii
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#if !defined(__GNUC__) && !defined(__clang__)
#error "flyology_bench requires GNU-style inline assembly barriers"
#endif

#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <libproc.h>
#include <mach/mach.h>
#include <mach/processor_info.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>

static mach_timebase_info_data_t flyology_bench_timebase;
static kern_return_t flyology_bench_timebase_status;
static pthread_once_t flyology_bench_timebase_once = PTHREAD_ONCE_INIT;

static void flyology_bench_initialize_timebase(void)
{
    flyology_bench_timebase_status =
        mach_timebase_info(&flyology_bench_timebase);
}
#elif defined(__linux__)
#include <linux/perf_event.h>
#include <sched.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#else
#error "flyology_bench clock supports Darwin and Linux"
#endif

int flyology_bench_clock_now(uint64_t *nanoseconds)
{
    if (nanoseconds == NULL) {
        errno = EINVAL;
        return -1;
    }
#if defined(__APPLE__)
    __uint128_t converted;

    if (pthread_once(&flyology_bench_timebase_once,
                     flyology_bench_initialize_timebase) != 0
        || flyology_bench_timebase_status != KERN_SUCCESS
        || flyology_bench_timebase.denom == 0) {
        errno = EIO;
        return -1;
    }
    converted = (__uint128_t)mach_absolute_time()
        * flyology_bench_timebase.numer;
    converted /= flyology_bench_timebase.denom;
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
    *nanoseconds = (uint64_t)value.tv_sec * UINT64_C(1000000000)
        + (uint64_t)value.tv_nsec;
    return 0;
#endif
}

int flyology_bench_clock_resolution(uint64_t *nanoseconds)
{
    if (nanoseconds == NULL) {
        errno = EINVAL;
        return -1;
    }
#if defined(__APPLE__)
    __uint128_t resolution;

    if (pthread_once(&flyology_bench_timebase_once,
                     flyology_bench_initialize_timebase) != 0
        || flyology_bench_timebase_status != KERN_SUCCESS
        || flyology_bench_timebase.denom == 0) {
        errno = EIO;
        return -1;
    }
    resolution = ((__uint128_t)flyology_bench_timebase.numer
                  + flyology_bench_timebase.denom - 1)
        / flyology_bench_timebase.denom;
    *nanoseconds = resolution == 0 ? 1 : (uint64_t)resolution;
    return 0;
#else
    struct timespec value;

    if (clock_getres(CLOCK_MONOTONIC_RAW, &value) != 0) {
        return -1;
    }
    *nanoseconds = (uint64_t)value.tv_sec * UINT64_C(1000000000)
        + (uint64_t)value.tv_nsec;
    return 0;
#endif
}

int flyology_bench_clock_backend(void)
{
#if defined(__APPLE__)
    return 1;
#else
    return 2;
#endif
}

int flyology_bench_platform_os(void)
{
#if defined(__APPLE__)
    return 1;
#else
    return 2;
#endif
}

int flyology_bench_platform_architecture(void)
{
#if defined(__aarch64__) || defined(__arm64__)
    return 1;
#elif defined(__x86_64__)
    return 2;
#else
    return 0;
#endif
}

int flyology_bench_pin_current_thread(unsigned int cpu)
{
#if defined(__APPLE__)
    if (cpu >= (unsigned int)INT_MAX) {
        errno = EINVAL;
        return -1;
    }
    thread_affinity_policy_data_t policy = {(integer_t)(cpu + 1)};
    thread_port_t thread = mach_thread_self();
    kern_return_t status = thread_policy_set(
        thread, THREAD_AFFINITY_POLICY,
        (thread_policy_t)&policy, THREAD_AFFINITY_POLICY_COUNT);
    (void)mach_port_deallocate(mach_task_self(), thread);
    if (status != KERN_SUCCESS) {
        errno = EINVAL;
        return -1;
    }
    return 1;
#else
    cpu_set_t set;
    int status;

    if (cpu >= CPU_SETSIZE) {
        errno = EINVAL;
        return -1;
    }
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    status = pthread_setaffinity_np(pthread_self(), sizeof(set), &set);
    if (status != 0) {
        errno = status;
        return -1;
    }
    return 2;
#endif
}

int flyology_bench_process_usage(uint64_t *cpu_nanoseconds,
                                 uint64_t *resident_bytes)
{
    struct rusage usage;

    if (cpu_nanoseconds == NULL || resident_bytes == NULL) {
        errno = EINVAL;
        return -1;
    }
    if (getrusage(RUSAGE_SELF, &usage) != 0) {
        return -1;
    }
    *cpu_nanoseconds =
        (uint64_t)usage.ru_utime.tv_sec * UINT64_C(1000000000)
        + (uint64_t)usage.ru_utime.tv_usec * UINT64_C(1000)
        + (uint64_t)usage.ru_stime.tv_sec * UINT64_C(1000000000)
        + (uint64_t)usage.ru_stime.tv_usec * UINT64_C(1000);
#if defined(__APPLE__)
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;

    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                  (task_info_t)&info, &count) != KERN_SUCCESS) {
        return -1;
    }
    *resident_bytes = (uint64_t)info.resident_size;
#else
    FILE *statm;
    unsigned long ignored_pages;
    unsigned long resident_pages;
    long page_size;

    statm = fopen("/proc/self/statm", "r");
    if (statm == NULL) {
        return -1;
    }
    if (fscanf(statm, "%lu %lu", &ignored_pages, &resident_pages) != 2) {
        (void)fclose(statm);
        errno = EIO;
        return -1;
    }
    (void)fclose(statm);
    page_size = sysconf(_SC_PAGESIZE);
    if (page_size <= 0) {
        errno = EIO;
        return -1;
    }
    *resident_bytes = (uint64_t)resident_pages * (uint64_t)page_size;
#endif
    return 0;
}

enum flyology_bench_resource_index {
    FLYOLOGY_BENCH_PROCESS_CPU = 0,
    FLYOLOGY_BENCH_THREAD_CPU,
    FLYOLOGY_BENCH_RSS,
    FLYOLOGY_BENCH_MINOR_FAULTS,
    FLYOLOGY_BENCH_MAJOR_FAULTS,
    FLYOLOGY_BENCH_VOLUNTARY_SWITCHES,
    FLYOLOGY_BENCH_INVOLUNTARY_SWITCHES,
    FLYOLOGY_BENCH_DISK_READ_BYTES,
    FLYOLOGY_BENCH_DISK_WRITTEN_BYTES,
    FLYOLOGY_BENCH_INPUT_OPERATIONS,
    FLYOLOGY_BENCH_OUTPUT_OPERATIONS,
    FLYOLOGY_BENCH_RESOURCE_COUNT
};

static uint64_t flyology_bench_timeval_nanoseconds(struct timeval value)
{
    return (uint64_t)value.tv_sec * UINT64_C(1000000000)
        + (uint64_t)value.tv_usec * UINT64_C(1000);
}

static void flyology_bench_mark_resource(uint64_t *mask, unsigned int index)
{
    *mask |= UINT64_C(1) << index;
}

int flyology_bench_resource_snapshot(uint64_t *values,
                                     size_t capacity,
                                     uint64_t *available_mask)
{
    struct rusage usage;
    uint64_t mask = 0;

    if (values == NULL || available_mask == NULL
        || capacity < FLYOLOGY_BENCH_RESOURCE_COUNT) {
        errno = EINVAL;
        return -1;
    }
    memset(values, 0, capacity * sizeof(*values));
    if (getrusage(RUSAGE_SELF, &usage) != 0) {
        return -1;
    }
    values[FLYOLOGY_BENCH_PROCESS_CPU] =
        flyology_bench_timeval_nanoseconds(usage.ru_utime)
        + flyology_bench_timeval_nanoseconds(usage.ru_stime);
    values[FLYOLOGY_BENCH_MINOR_FAULTS] = (uint64_t)usage.ru_minflt;
    values[FLYOLOGY_BENCH_MAJOR_FAULTS] = (uint64_t)usage.ru_majflt;
    values[FLYOLOGY_BENCH_VOLUNTARY_SWITCHES] = (uint64_t)usage.ru_nvcsw;
    values[FLYOLOGY_BENCH_INVOLUNTARY_SWITCHES] = (uint64_t)usage.ru_nivcsw;
    values[FLYOLOGY_BENCH_INPUT_OPERATIONS] = (uint64_t)usage.ru_inblock;
    values[FLYOLOGY_BENCH_OUTPUT_OPERATIONS] = (uint64_t)usage.ru_oublock;
    flyology_bench_mark_resource(&mask, FLYOLOGY_BENCH_PROCESS_CPU);
    flyology_bench_mark_resource(&mask, FLYOLOGY_BENCH_MINOR_FAULTS);
    flyology_bench_mark_resource(&mask, FLYOLOGY_BENCH_MAJOR_FAULTS);
    flyology_bench_mark_resource(&mask, FLYOLOGY_BENCH_VOLUNTARY_SWITCHES);
    flyology_bench_mark_resource(&mask, FLYOLOGY_BENCH_INVOLUNTARY_SWITCHES);
    flyology_bench_mark_resource(&mask, FLYOLOGY_BENCH_INPUT_OPERATIONS);
    flyology_bench_mark_resource(&mask, FLYOLOGY_BENCH_OUTPUT_OPERATIONS);

#if defined(__APPLE__)
    {
        thread_basic_info_data_t info;
        mach_msg_type_number_t count = THREAD_BASIC_INFO_COUNT;
        thread_port_t thread = mach_thread_self();

        if (thread_info(thread, THREAD_BASIC_INFO, (thread_info_t)&info,
                        &count) == KERN_SUCCESS) {
            values[FLYOLOGY_BENCH_THREAD_CPU] =
                (uint64_t)info.user_time.seconds * UINT64_C(1000000000)
                + (uint64_t)info.user_time.microseconds * UINT64_C(1000)
                + (uint64_t)info.system_time.seconds * UINT64_C(1000000000)
                + (uint64_t)info.system_time.microseconds * UINT64_C(1000);
            flyology_bench_mark_resource(&mask, FLYOLOGY_BENCH_THREAD_CPU);
        }
        (void)mach_port_deallocate(mach_task_self(), thread);
    }
    {
        mach_task_basic_info_data_t info;
        mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;

        if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                      (task_info_t)&info, &count) == KERN_SUCCESS) {
            values[FLYOLOGY_BENCH_RSS] = (uint64_t)info.resident_size;
            flyology_bench_mark_resource(&mask, FLYOLOGY_BENCH_RSS);
        }
    }
    {
        struct rusage_info_v2 info;

        if (proc_pid_rusage(getpid(), RUSAGE_INFO_V2,
                            (rusage_info_t *)&info) == 0) {
            values[FLYOLOGY_BENCH_DISK_READ_BYTES] = info.ri_diskio_bytesread;
            values[FLYOLOGY_BENCH_DISK_WRITTEN_BYTES] =
                info.ri_diskio_byteswritten;
            flyology_bench_mark_resource(&mask,
                                          FLYOLOGY_BENCH_DISK_READ_BYTES);
            flyology_bench_mark_resource(&mask,
                                          FLYOLOGY_BENCH_DISK_WRITTEN_BYTES);
        }
    }
#else
    {
        struct timespec value;

        if (clock_gettime(CLOCK_THREAD_CPUTIME_ID, &value) == 0) {
            values[FLYOLOGY_BENCH_THREAD_CPU] =
                (uint64_t)value.tv_sec * UINT64_C(1000000000)
                + (uint64_t)value.tv_nsec;
            flyology_bench_mark_resource(&mask, FLYOLOGY_BENCH_THREAD_CPU);
        }
    }
    {
        FILE *statm = fopen("/proc/self/statm", "r");
        unsigned long ignored_pages;
        unsigned long resident_pages;
        long page_size;

        if (statm != NULL
            && fscanf(statm, "%lu %lu", &ignored_pages, &resident_pages) == 2
            && (page_size = sysconf(_SC_PAGESIZE)) > 0) {
            values[FLYOLOGY_BENCH_RSS] =
                (uint64_t)resident_pages * (uint64_t)page_size;
            flyology_bench_mark_resource(&mask, FLYOLOGY_BENCH_RSS);
        }
        if (statm != NULL) {
            (void)fclose(statm);
        }
    }
    {
        FILE *io = fopen("/proc/self/io", "r");
        char line[256];

        if (io != NULL) {
            while (fgets(line, sizeof(line), io) != NULL) {
                unsigned long long value;

                if (sscanf(line, "read_bytes: %llu", &value) == 1) {
                    values[FLYOLOGY_BENCH_DISK_READ_BYTES] = (uint64_t)value;
                    flyology_bench_mark_resource(
                        &mask, FLYOLOGY_BENCH_DISK_READ_BYTES);
                } else if (sscanf(line, "write_bytes: %llu", &value) == 1) {
                    values[FLYOLOGY_BENCH_DISK_WRITTEN_BYTES] =
                        (uint64_t)value;
                    flyology_bench_mark_resource(
                        &mask, FLYOLOGY_BENCH_DISK_WRITTEN_BYTES);
                }
            }
            (void)fclose(io);
        }
    }
#endif
    *available_mask = mask;
    return 0;
}

enum flyology_bench_perf_index {
    FLYOLOGY_BENCH_PERF_CYCLES = 0,
    FLYOLOGY_BENCH_PERF_INSTRUCTIONS,
    FLYOLOGY_BENCH_PERF_CACHE_MISSES,
    FLYOLOGY_BENCH_PERF_BRANCHES,
    FLYOLOGY_BENCH_PERF_BRANCH_MISSES,
    FLYOLOGY_BENCH_PERF_COUNT
};

enum flyology_bench_metric_status {
    FLYOLOGY_BENCH_METRIC_NOT_REQUESTED = 0,
    FLYOLOGY_BENCH_METRIC_COLLECTED,
    FLYOLOGY_BENCH_METRIC_UNSUPPORTED_PLATFORM,
    FLYOLOGY_BENCH_METRIC_PERMISSION_DENIED,
    FLYOLOGY_BENCH_METRIC_UNSUPPORTED_EVENT,
    FLYOLOGY_BENCH_METRIC_COUNTER_RESOURCES_UNAVAILABLE,
    FLYOLOGY_BENCH_METRIC_PROBE_FAILED
};

/* Per-sample values are read as differences between a baseline captured
 * while the counters are disabled and a final read taken after they are
 * disabled again. PERF_EVENT_IOC_RESET cannot be used instead: it clears only
 * the event's own count, never the inherited child_count that attr.inherit
 * accumulates, so a reset-and-read-absolute scheme reports counts that grow
 * monotonically across samples once child tasks contribute.
 */
struct flyology_bench_perf_state {
    int fds[FLYOLOGY_BENCH_PERF_COUNT];
    uint64_t available_mask;
    int statuses[FLYOLOGY_BENCH_PERF_COUNT];
    int cycles_instructions_grouped;
    uint64_t baseline_value[FLYOLOGY_BENCH_PERF_COUNT];
    uint64_t baseline_enabled[FLYOLOGY_BENCH_PERF_COUNT];
    uint64_t baseline_running[FLYOLOGY_BENCH_PERF_COUNT];
};

#if defined(__linux__)
/* Classifies an errno reported by a counter control or read operation.
 * EINVAL is deliberately absent: at open time it is ambiguous and is
 * resolved separately by flyology_bench_perf_event_probe_status, and on a
 * control or read path it means this code issued a malformed request.
 */
static int flyology_bench_perf_failure_status(int error)
{
    switch (error) {
    case EACCES:
    case EPERM:
        return FLYOLOGY_BENCH_METRIC_PERMISSION_DENIED;
    case ENODEV:
    case ENOENT:
    case EOPNOTSUPP:
        return FLYOLOGY_BENCH_METRIC_UNSUPPORTED_EVENT;
    case EBUSY:
    case EMFILE:
    case ENFILE:
    case ENOSPC:
        return FLYOLOGY_BENCH_METRIC_COUNTER_RESOURCES_UNAVAILABLE;
    default:
        return FLYOLOGY_BENCH_METRIC_PROBE_FAILED;
    }
}

/* Classifies a probe of the bare generic event.
 *
 * perf_event_open reports EINVAL both for a generic event that the host PMU
 * cannot map (x86 returns EINVAL where arm64 returns ENOENT) and for a
 * perf_event_attr combination the kernel rejects. Re-opening the event with
 * only the permission-relevant attributes separates the two: the excludes
 * are retained so a paranoid-level rejection still surfaces as a failure
 * rather than being misread as an unsupported event.
 */
static int flyology_bench_perf_event_probe_status(uint64_t config)
{
    struct perf_event_attr attr;
    int fd;

    memset(&attr, 0, sizeof(attr));
    attr.type = PERF_TYPE_HARDWARE;
    attr.size = sizeof(attr);
    attr.config = config;
    attr.disabled = 1;
    attr.exclude_kernel = 1;
    attr.exclude_hv = 1;
    fd = (int)syscall(__NR_perf_event_open, &attr, 0, -1, -1, 0);
    if (fd < 0) {
        /* A bare generic event is unsupported when the PMU cannot map it.
         * Preserve permission and resource failures instead of collapsing
         * every unsuccessful re-probe into Unsupported_Event.
         */
        if (errno == EINVAL) {
            return FLYOLOGY_BENCH_METRIC_UNSUPPORTED_EVENT;
        }
        return flyology_bench_perf_failure_status(errno);
    }
    (void)close(fd);
    return FLYOLOGY_BENCH_METRIC_COLLECTED;
}

/* Classifies a failed perf_event_open for one requested event. */
static int flyology_bench_perf_open_status(int error, uint64_t config)
{
    if (error == EINVAL) {
        int probe_status = flyology_bench_perf_event_probe_status(config);

        return probe_status == FLYOLOGY_BENCH_METRIC_COLLECTED
            ? FLYOLOGY_BENCH_METRIC_PROBE_FAILED
            : probe_status;
    }
    return flyology_bench_perf_failure_status(error);
}

static void flyology_bench_perf_close_event(
    struct flyology_bench_perf_state *state, unsigned int index, int status)
{
    if (state->fds[index] >= 0) {
        (void)close(state->fds[index]);
        state->fds[index] = -1;
    }
    state->available_mask &= ~(UINT64_C(1) << index);
    state->statuses[index] = status;
}

static void flyology_bench_perf_close_ipc_group(
    struct flyology_bench_perf_state *state, int status)
{
    flyology_bench_perf_close_event(
        state, FLYOLOGY_BENCH_PERF_CYCLES, status);
    flyology_bench_perf_close_event(
        state, FLYOLOGY_BENCH_PERF_INSTRUCTIONS, status);
    state->cycles_instructions_grouped = 0;
}

/* Retires one event. Cycles and instructions are retired together while
 * they share a counting group so instructions per cycle is never formed
 * from two differently bounded windows.
 */
static void flyology_bench_perf_fail_event(
    struct flyology_bench_perf_state *state, unsigned int index, int status)
{
    if (state->cycles_instructions_grouped
        && (index == FLYOLOGY_BENCH_PERF_CYCLES
            || index == FLYOLOGY_BENCH_PERF_INSTRUCTIONS)) {
        flyology_bench_perf_close_ipc_group(state, status);
    } else {
        flyology_bench_perf_close_event(state, index, status);
    }
}

/* Reads one counter together with its multiplexing time accounting.
 * Returns 0 on success, or -1 with *status set to the failure class.
 */
static int flyology_bench_perf_read_counter(int fd,
                                            uint64_t *value,
                                            uint64_t *enabled,
                                            uint64_t *running,
                                            int *status)
{
    struct {
        uint64_t value;
        uint64_t time_enabled;
        uint64_t time_running;
    } result;
    ssize_t bytes_read = read(fd, &result, sizeof(result));

    if (bytes_read != (ssize_t)sizeof(result)) {
        *status = bytes_read < 0
            ? flyology_bench_perf_failure_status(errno)
            : FLYOLOGY_BENCH_METRIC_PROBE_FAILED;
        return -1;
    }
    *value = result.value;
    *enabled = result.time_enabled;
    *running = result.time_running;
    return 0;
}
#endif

int flyology_bench_perf_initialize(struct flyology_bench_perf_state *state,
                                   uint64_t requested_mask)
{
    if (state == NULL) {
        errno = EINVAL;
        return -1;
    }
    for (unsigned int index = 0; index < FLYOLOGY_BENCH_PERF_COUNT; ++index) {
        state->fds[index] = -1;
        state->statuses[index] = FLYOLOGY_BENCH_METRIC_NOT_REQUESTED;
        state->baseline_value[index] = 0;
        state->baseline_enabled[index] = 0;
        state->baseline_running[index] = 0;
    }
    state->available_mask = 0;
    state->cycles_instructions_grouped = 0;
#if defined(__linux__)
    static const uint64_t configs[FLYOLOGY_BENCH_PERF_COUNT] = {
        PERF_COUNT_HW_CPU_CYCLES,
        PERF_COUNT_HW_INSTRUCTIONS,
        PERF_COUNT_HW_CACHE_MISSES,
        PERF_COUNT_HW_BRANCH_INSTRUCTIONS,
        PERF_COUNT_HW_BRANCH_MISSES
    };

    for (unsigned int index = 0; index < FLYOLOGY_BENCH_PERF_COUNT; ++index) {
        struct perf_event_attr attr;
        int fd;
        int group_fd = -1;

        if ((requested_mask & (UINT64_C(1) << index)) == 0) {
            continue;
        }
        memset(&attr, 0, sizeof(attr));
        attr.type = PERF_TYPE_HARDWARE;
        attr.size = sizeof(attr);
        attr.config = configs[index];
        if (index == FLYOLOGY_BENCH_PERF_INSTRUCTIONS
            && state->fds[FLYOLOGY_BENCH_PERF_CYCLES] >= 0) {
            group_fd = state->fds[FLYOLOGY_BENCH_PERF_CYCLES];
        }
        attr.disabled = group_fd < 0;
        attr.inherit = 1;
        attr.inherit_stat = 1;
        attr.exclude_kernel = 1;
        attr.exclude_hv = 1;
        attr.read_format = PERF_FORMAT_TOTAL_TIME_ENABLED
            | PERF_FORMAT_TOTAL_TIME_RUNNING;
        fd = (int)syscall(
            __NR_perf_event_open, &attr, 0, -1, group_fd, 0);
        if (fd >= 0) {
            state->fds[index] = fd;
            state->available_mask |= UINT64_C(1) << index;
            state->statuses[index] = FLYOLOGY_BENCH_METRIC_COLLECTED;
            if (group_fd >= 0) {
                state->cycles_instructions_grouped = 1;
            }
        } else {
            state->statuses[index] =
                flyology_bench_perf_open_status(errno, configs[index]);
        }
    }
#else
    for (unsigned int index = 0; index < FLYOLOGY_BENCH_PERF_COUNT; ++index) {
        if ((requested_mask & (UINT64_C(1) << index)) != 0) {
            state->statuses[index] =
                FLYOLOGY_BENCH_METRIC_UNSUPPORTED_PLATFORM;
        }
    }
#endif
    return 0;
}

int flyology_bench_perf_start(struct flyology_bench_perf_state *state)
{
    if (state == NULL) {
        errno = EINVAL;
        return -1;
    }
#if defined(__linux__)
    /* Read every baseline before enabling any event. In particular, cycles
     * and instructions must not acquire baselines at different instants:
     * their group enable below then gives both sides of IPC one identical
     * counting interval. The descriptors retain totals across samples so
     * inherited child counts are included without relying on RESET.
     */
    for (unsigned int index = 0; index < FLYOLOGY_BENCH_PERF_COUNT; ++index) {
        int status = FLYOLOGY_BENCH_METRIC_PROBE_FAILED;

        if (state->fds[index] < 0) {
            continue;
        }
        if (flyology_bench_perf_read_counter(state->fds[index],
                                             &state->baseline_value[index],
                                             &state->baseline_enabled[index],
                                             &state->baseline_running[index],
                                             &status) != 0) {
            flyology_bench_perf_fail_event(state, index, status);
        }
    }
    if (state->cycles_instructions_grouped) {
        int leader = state->fds[FLYOLOGY_BENCH_PERF_CYCLES];

        if (leader < 0
            || ioctl(leader, PERF_EVENT_IOC_ENABLE, PERF_IOC_FLAG_GROUP) != 0) {
            int status = flyology_bench_perf_failure_status(errno);
            flyology_bench_perf_close_ipc_group(state, status);
        }
    }
    for (unsigned int index = 0; index < FLYOLOGY_BENCH_PERF_COUNT; ++index) {
        if (state->cycles_instructions_grouped
            && (index == FLYOLOGY_BENCH_PERF_CYCLES
                || index == FLYOLOGY_BENCH_PERF_INSTRUCTIONS)) {
            continue;
        }
        if (state->fds[index] >= 0
            && ioctl(state->fds[index], PERF_EVENT_IOC_ENABLE, 0) != 0) {
            flyology_bench_perf_close_event(
                state, index, flyology_bench_perf_failure_status(errno));
        }
    }
#endif
    return 0;
}

int flyology_bench_perf_finish(struct flyology_bench_perf_state *state,
                               uint64_t *values,
                               size_t capacity,
                               uint64_t *available_mask)
{
    if (state == NULL || values == NULL || available_mask == NULL
        || capacity < FLYOLOGY_BENCH_PERF_COUNT) {
        errno = EINVAL;
        return -1;
    }
    memset(values, 0, capacity * sizeof(*values));
#if defined(__linux__)
    if (state->cycles_instructions_grouped) {
        int leader = state->fds[FLYOLOGY_BENCH_PERF_CYCLES];

        if (leader < 0
            || ioctl(leader, PERF_EVENT_IOC_DISABLE, PERF_IOC_FLAG_GROUP) != 0) {
            int status = flyology_bench_perf_failure_status(errno);
            flyology_bench_perf_close_ipc_group(state, status);
        }
    }
    for (unsigned int index = 0; index < FLYOLOGY_BENCH_PERF_COUNT; ++index) {
        if (state->cycles_instructions_grouped
            && (index == FLYOLOGY_BENCH_PERF_CYCLES
                || index == FLYOLOGY_BENCH_PERF_INSTRUCTIONS)) {
            continue;
        }
        if (state->fds[index] >= 0
            && ioctl(state->fds[index], PERF_EVENT_IOC_DISABLE, 0) != 0) {
            flyology_bench_perf_close_event(
                state, index, flyology_bench_perf_failure_status(errno));
        }
    }
    for (unsigned int index = 0; index < FLYOLOGY_BENCH_PERF_COUNT; ++index) {
        uint64_t value;
        uint64_t enabled;
        uint64_t running;
        uint64_t counted;
        uint64_t enabled_delta;
        uint64_t running_delta;
        long double scaled;
        int status = FLYOLOGY_BENCH_METRIC_PROBE_FAILED;

        if (state->fds[index] < 0) {
            continue;
        }
        if (flyology_bench_perf_read_counter(state->fds[index], &value,
                                             &enabled, &running,
                                             &status) != 0) {
            flyology_bench_perf_fail_event(state, index, status);
            continue;
        }
        /* All three totals accumulate for the life of the descriptor, so a
         * sample is the difference against the baseline captured in
         * flyology_bench_perf_start. A total that moved backwards would mean
         * the kernel's accounting is not usable here.
         */
        if (value < state->baseline_value[index]
            || enabled < state->baseline_enabled[index]
            || running < state->baseline_running[index]) {
            flyology_bench_perf_fail_event(
                state, index, FLYOLOGY_BENCH_METRIC_PROBE_FAILED);
            continue;
        }
        counted = value - state->baseline_value[index];
        enabled_delta = enabled - state->baseline_enabled[index];
        running_delta = running - state->baseline_running[index];
        if (running_delta == 0) {
            flyology_bench_perf_fail_event(
                state, index,
                FLYOLOGY_BENCH_METRIC_COUNTER_RESOURCES_UNAVAILABLE);
            continue;
        }
        scaled = (long double)counted * (long double)enabled_delta
            / (long double)running_delta;
        if (scaled > (long double)UINT64_MAX) {
            flyology_bench_perf_fail_event(
                state, index, FLYOLOGY_BENCH_METRIC_PROBE_FAILED);
            continue;
        }
        values[index] = (uint64_t)scaled;
    }
#endif
    *available_mask = state->available_mask;
    return 0;
}

void flyology_bench_perf_close(struct flyology_bench_perf_state *state)
{
    if (state == NULL) {
        return;
    }
    for (unsigned int index = 0; index < FLYOLOGY_BENCH_PERF_COUNT; ++index) {
        if (state->fds[index] >= 0) {
            (void)close(state->fds[index]);
            state->fds[index] = -1;
        }
    }
    state->available_mask = 0;
    state->cycles_instructions_grouped = 0;
}

int flyology_bench_host_cpu_snapshot(uint64_t *busy_ticks,
                                     uint64_t *total_ticks,
                                     size_t capacity,
                                     size_t *cpu_count)
{
    if (busy_ticks == NULL || total_ticks == NULL || cpu_count == NULL
        || capacity == 0) {
        errno = EINVAL;
        return -1;
    }
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
    FILE *stat_file = fopen("/proc/stat", "r");
    char line[1024];
    size_t seen = 0;

    if (stat_file == NULL) {
        return -1;
    }
    while (fgets(line, sizeof(line), stat_file) != NULL) {
        unsigned int cpu;
        unsigned long long user;
        unsigned long long nice;
        unsigned long long system;
        unsigned long long idle;
        unsigned long long iowait;
        unsigned long long irq;
        unsigned long long softirq;
        unsigned long long steal;
        int fields;

        if (strncmp(line, "cpu", 3) != 0) {
            break;
        }
        fields = sscanf(line,
                        "cpu%u %llu %llu %llu %llu %llu %llu %llu %llu",
                        &cpu, &user, &nice, &system, &idle, &iowait, &irq,
                        &softirq, &steal);
        if (fields == 0) {
            continue;
        }
        if (fields != 9 || seen >= capacity) {
            (void)fclose(stat_file);
            errno = fields == 9 ? ENOSPC : EIO;
            return -1;
        }
        (void)cpu;
        busy_ticks[seen] = (uint64_t)user + (uint64_t)nice
            + (uint64_t)system + (uint64_t)irq + (uint64_t)softirq
            + (uint64_t)steal;
        total_ticks[seen] = busy_ticks[seen] + (uint64_t)idle
            + (uint64_t)iowait;
        ++seen;
    }
    if (fclose(stat_file) != 0 || seen == 0) {
        errno = EIO;
        return -1;
    }
    *cpu_count = seen;
    return 0;
#endif
}

void flyology_bench_escape(void *value)
{
    __asm__ __volatile__("" : : "g"(value) : "memory");
}

void flyology_bench_clobber_memory(void)
{
    __asm__ __volatile__("" : : : "memory");
}
