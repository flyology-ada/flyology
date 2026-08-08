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
#include <sched.h>
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
