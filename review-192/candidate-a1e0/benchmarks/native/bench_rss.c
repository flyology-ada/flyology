/*  Copyright (c) 2026 Yurii Rashkovskii
 *  SPDX-License-Identifier: MIT OR Apache-2.0
 *
 *  Current resident set size in bytes, so a benchmark can attribute committed
 *  memory to the fibers it holds live. Peak counters are unusable here because
 *  the measurement compares two configurations inside one process lifetime.
 */

#include <stddef.h>

#if defined(__APPLE__)

#include <mach/mach.h>

unsigned long long flyology_bench_resident_bytes(void) {
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;

    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                  (task_info_t) &info, &count) != KERN_SUCCESS) {
        return 0;
    }
    return (unsigned long long) info.resident_size;
}

#elif defined(__linux__)

#include <stdio.h>
#include <unistd.h>

unsigned long long flyology_bench_resident_bytes(void) {
    unsigned long long total = 0;
    unsigned long long resident = 0;
    FILE *statm = fopen("/proc/self/statm", "r");

    if (statm == NULL) {
        return 0;
    }
    if (fscanf(statm, "%llu %llu", &total, &resident) != 2) {
        resident = 0;
    }
    fclose(statm);
    return resident * (unsigned long long) sysconf(_SC_PAGESIZE);
}

#else

unsigned long long flyology_bench_resident_bytes(void) {
    return 0;
}

#endif
