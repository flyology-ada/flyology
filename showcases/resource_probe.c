#include <stdint.h>
#include <stdio.h>
#include <sys/resource.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <mach/mach.h>
#endif

int64_t gnatevl_current_rss_bytes(void) {
#if defined(__APPLE__)
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;

    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                  (task_info_t)&info, &count) != KERN_SUCCESS) {
        return -1;
    }
    return (int64_t)info.resident_size;
#elif defined(__linux__)
    FILE *status = fopen("/proc/self/statm", "r");
    long pages = 0;
    long resident = 0;

    if (status == NULL || fscanf(status, "%ld %ld", &pages, &resident) != 2) {
        if (status != NULL) {
            fclose(status);
        }
        return -1;
    }
    fclose(status);
    return (int64_t)resident * (int64_t)sysconf(_SC_PAGESIZE);
#else
    return -1;
#endif
}

int64_t gnatevl_virtual_bytes(void) {
#if defined(__APPLE__)
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;

    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                  (task_info_t)&info, &count) != KERN_SUCCESS) {
        return -1;
    }
    return (int64_t)info.virtual_size;
#elif defined(__linux__)
    FILE *status = fopen("/proc/self/statm", "r");
    long pages = 0;
    long resident = 0;

    if (status == NULL || fscanf(status, "%ld %ld", &pages, &resident) != 2) {
        if (status != NULL) {
            fclose(status);
        }
        return -1;
    }
    fclose(status);
    return (int64_t)pages * (int64_t)sysconf(_SC_PAGESIZE);
#else
    return -1;
#endif
}

int64_t gnatevl_peak_rss_bytes(void) {
    struct rusage usage;

    if (getrusage(RUSAGE_SELF, &usage) != 0) {
        return -1;
    }
#if defined(__APPLE__)
    return (int64_t)usage.ru_maxrss;
#elif defined(__linux__)
    return (int64_t)usage.ru_maxrss * 1024;
#else
    return -1;
#endif
}

int gnatevl_thread_count(void) {
#if defined(__APPLE__)
    thread_act_array_t threads;
    mach_msg_type_number_t count = 0;

    if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) {
        return -1;
    }
    vm_deallocate(mach_task_self(), (vm_address_t)threads,
                  (vm_size_t)count * sizeof(*threads));
    return (int)count;
#elif defined(__linux__)
    FILE *status = fopen("/proc/self/status", "r");
    char line[256];
    int count = -1;

    if (status == NULL) {
        return -1;
    }
    while (fgets(line, sizeof(line), status) != NULL) {
        if (sscanf(line, "Threads: %d", &count) == 1) {
            break;
        }
    }
    fclose(status);
    return count;
#else
    return -1;
#endif
}
