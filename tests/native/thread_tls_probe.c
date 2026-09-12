#define _GNU_SOURCE

#include <stdint.h>

#if defined(__linux__)
#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <stddef.h>
#include <string.h>
#endif

/* Deliberately real pthread-local state, separate from Ada task state. */
static _Thread_local uintptr_t flyology_test_tls_value;

uintptr_t flyology_test_tls_get(void) {
    return flyology_test_tls_value;
}

void flyology_test_tls_set(uintptr_t value) {
    flyology_test_tls_value = value;
}

#if defined(__linux__)

/* cpu_set_t inspection uses glibc's macro-only CPU_* interface. */
size_t flyology_test_thread_affinity_size(void) {
    return sizeof(cpu_set_t);
}

int flyology_test_thread_affinity_observable_cpu(void) {
    cpu_set_t set;
    int result = pthread_getaffinity_np(pthread_self(), sizeof(set), &set);

    if (result != 0) {
        return -result;
    }
    if (CPU_COUNT(&set) < 2) {
        return 0;
    }
    for (int cpu = 0; cpu < CPU_SETSIZE; ++cpu) {
        if (CPU_ISSET(cpu, &set)) {
            /* Ada CPU_Range reserves zero as Not_A_Specific_CPU. */
            return cpu + 1;
        }
    }
    return 0;
}

int flyology_test_thread_affinity_snapshot(void *storage, size_t size) {
    cpu_set_t set;
    int result;

    if (storage == NULL || size != sizeof(set)) {
        return EINVAL;
    }
    result = pthread_getaffinity_np(pthread_self(), sizeof(set), &set);
    if (result == 0) {
        memcpy(storage, &set, sizeof(set));
    }
    return result;
}

#endif
