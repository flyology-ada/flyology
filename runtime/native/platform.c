#include <sys/mman.h>
#include <stdint.h>

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
