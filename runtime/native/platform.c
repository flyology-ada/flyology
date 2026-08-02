#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <sys/mman.h>
#include <pthread.h>
#include <errno.h>
#include <stdint.h>
#include <unistd.h>

#if defined(__linux__)
#include <sched.h>
#elif defined(__APPLE__)
#include <mach/mach.h>
#include <mach/thread_policy.h>
#endif

#define GNATEVL_PLACEMENT_STRICT 1
#define GNATEVL_PLACEMENT_ADVISORY 2
#define GNATEVL_PLACEMENT_UNSUPPORTED (-1)
#define GNATEVL_PLACEMENT_INVALID (-2)

#if defined(__linux__)
static cpu_set_t gnatevl_initial_cpu_mask;
static int gnatevl_initial_cpu_mask_valid;
#endif
static pthread_once_t gnatevl_placement_once = PTHREAD_ONCE_INIT;
static int gnatevl_placement_initialization_result;

/*
 * Capture the Linux process leader's CPU allowance. Unlike pthread_self(),
 * getpid() continues to name the leader when a placement request originates
 * on an already-narrowed native or event-loop thread. The scheduler owns
 * placement policy; these helpers only bridge macro-only OS interfaces and
 * verify kernel state.
 */
static void gnatevl_thread_placement_initialize_once(void) {
#if defined(__linux__)
    int result = sched_getaffinity(getpid(), sizeof(gnatevl_initial_cpu_mask),
                                   &gnatevl_initial_cpu_mask);
    gnatevl_initial_cpu_mask_valid = result == 0;
    gnatevl_placement_initialization_result = result == 0 ? 0 : errno;
#endif
}

int gnatevl_thread_placement_initialize(void) {
    int result = pthread_once(&gnatevl_placement_once,
                              gnatevl_thread_placement_initialize_once);
    return result == 0 ? gnatevl_placement_initialization_result : result;
}

static int gnatevl_thread_placement_platform_ready(void) {
    return gnatevl_thread_placement_initialize() == 0;
}

int gnatevl_thread_placement_supported(int mode) {
    if (!gnatevl_thread_placement_platform_ready()) {
        return 0;
    }
#if defined(__linux__)
    return mode == GNATEVL_PLACEMENT_STRICT &&
           gnatevl_initial_cpu_mask_valid;
#elif defined(__APPLE__)
#if defined(__aarch64__) || defined(__arm64__)
    (void)mode;
    return 0;
#else
    return mode == GNATEVL_PLACEMENT_ADVISORY;
#endif
#else
    (void)mode;
    return 0;
#endif
}

int gnatevl_thread_placement_validate(int mode, int value) {
    if (!gnatevl_thread_placement_supported(mode)) {
        return GNATEVL_PLACEMENT_UNSUPPORTED;
    }
#if defined(__linux__)
    if (!gnatevl_initial_cpu_mask_valid || value < 0 || value >= CPU_SETSIZE ||
        !CPU_ISSET(value, &gnatevl_initial_cpu_mask)) {
        return GNATEVL_PLACEMENT_INVALID;
    }
    return 0;
#elif defined(__APPLE__)
    return value > 0 ? 0 : GNATEVL_PLACEMENT_INVALID;
#endif
}

int gnatevl_thread_placement_apply(int mode, int value) {
    int valid = gnatevl_thread_placement_validate(mode, value);

    if (valid != 0) {
        return valid;
    }
#if defined(__linux__)
    cpu_set_t requested;
    cpu_set_t effective;
    int result;

    CPU_ZERO(&requested);
    CPU_SET(value, &requested);
    result = pthread_setaffinity_np(pthread_self(), sizeof(requested),
                                    &requested);
    if (result != 0) {
        return result;
    }
    result = pthread_getaffinity_np(pthread_self(), sizeof(effective),
                                    &effective);
    if (result != 0) {
        return result;
    }
    if (CPU_COUNT(&effective) != 1 || !CPU_ISSET(value, &effective)) {
        return EIO;
    }
    return 0;
#elif defined(__APPLE__)
    thread_affinity_policy_data_t requested = { value };
    thread_port_t thread = pthread_mach_thread_np(pthread_self());
    kern_return_t result;

    result = thread_policy_set(thread, THREAD_AFFINITY_POLICY,
                               (thread_policy_t)&requested,
                               THREAD_AFFINITY_POLICY_COUNT);
    /* Darwin offers no supported read-back or physical-CPU guarantee for
       this hint. Applied means the kernel accepted thread_policy_set. */
    return result == KERN_SUCCESS ? 0 : (int)result;
#endif
}

int gnatevl_thread_current_processor(void) {
#if defined(__linux__)
    return sched_getcpu();
#else
    /* Darwin exposes no stable public physical-CPU identity contract. */
    return -1;
#endif
}

static uint32_t *gnatevl_fork_child_flag;

static void gnatevl_mark_fork_child(void) {
    __atomic_store_n(gnatevl_fork_child_flag, 1, __ATOMIC_RELAXED);
}

int gnatevl_install_fork_guard(void *flag) {
    if (flag == NULL || gnatevl_fork_child_flag != NULL) {
        return -1;
    }
    gnatevl_fork_child_flag = (uint32_t *)flag;
    return pthread_atfork(NULL, NULL, gnatevl_mark_fork_child);
}

#ifdef GNATEVL_TEST_FAULTS
#include <stdatomic.h>

#define GNATEVL_FAULT_POINT_COUNT 8

struct gnatevl_fault_plan {
    atomic_uint calls;
    atomic_uint first;
    atomic_uint count;
};

static struct gnatevl_fault_plan
    gnatevl_faults[GNATEVL_FAULT_POINT_COUNT + 1];

int gnatevl_test_faults_enabled(void) {
    return 1;
}

void gnatevl_test_fault_reset(void) {
    unsigned point;

    for (point = 1; point <= GNATEVL_FAULT_POINT_COUNT; ++point) {
        atomic_store_explicit(&gnatevl_faults[point].calls, 0,
                              memory_order_relaxed);
        atomic_store_explicit(&gnatevl_faults[point].first, 0,
                              memory_order_relaxed);
        atomic_store_explicit(&gnatevl_faults[point].count, 0,
                              memory_order_release);
    }
}

int gnatevl_test_fault_arm(int point, unsigned first, unsigned count) {
    if (point < 1 || point > GNATEVL_FAULT_POINT_COUNT) {
        return -1;
    }
    atomic_store_explicit(&gnatevl_faults[point].calls, 0,
                          memory_order_relaxed);
    atomic_store_explicit(&gnatevl_faults[point].first, first,
                          memory_order_relaxed);
    atomic_store_explicit(&gnatevl_faults[point].count, count,
                          memory_order_release);
    return 0;
}

unsigned gnatevl_test_fault_calls(int point) {
    if (point < 1 || point > GNATEVL_FAULT_POINT_COUNT) {
        return 0;
    }
    return atomic_load_explicit(&gnatevl_faults[point].calls,
                                memory_order_relaxed);
}

int gnatevl_test_fault_hit(int point) {
    struct gnatevl_fault_plan *plan;
    unsigned call;
    unsigned first;
    unsigned count;

    if (point < 1 || point > GNATEVL_FAULT_POINT_COUNT) {
        return 0;
    }
    plan = &gnatevl_faults[point];
    call = atomic_fetch_add_explicit(&plan->calls, 1,
                                     memory_order_relaxed);
    count = atomic_load_explicit(&plan->count, memory_order_acquire);
    if (count == 0) {
        return 0;
    }
    first = atomic_load_explicit(&plan->first, memory_order_relaxed);
    return call >= first && call - first < count;
}
#else
int gnatevl_test_faults_enabled(void) {
    return 0;
}

void gnatevl_test_fault_reset(void) {
}

int gnatevl_test_fault_arm(int point, unsigned first, unsigned count) {
    (void)point;
    (void)first;
    (void)count;
    return -1;
}

unsigned gnatevl_test_fault_calls(int point) {
    (void)point;
    return 0;
}

int gnatevl_test_fault_hit(int point) {
    (void)point;
    return 0;
}
#endif

int gnatevl_map_anonymous(void) {
    return MAP_ANONYMOUS;
}

void gnatevl_atomic_store_u32(void *address, uint32_t value, int model) {
    __atomic_store_n((uint32_t *)address, value, model);
}
