#include <stdatomic.h>

static _Atomic int events_lost_once;
static _Atomic int remove_failure_once;
static _Atomic int close_failure_once;

void flyology_test_file_watch_reset(void) {
    atomic_store_explicit(&events_lost_once, 0, memory_order_relaxed);
    atomic_store_explicit(&remove_failure_once, 0, memory_order_relaxed);
    atomic_store_explicit(&close_failure_once, 0, memory_order_relaxed);
}

void flyology_test_file_watch_events_lost_once(void) {
    atomic_store_explicit(&events_lost_once, 1, memory_order_relaxed);
}

void flyology_test_file_watch_remove_fail_once(void) {
    atomic_store_explicit(&remove_failure_once, 1, memory_order_relaxed);
}

void flyology_test_file_watch_close_fail_once(void) {
    atomic_store_explicit(&close_failure_once, 1, memory_order_relaxed);
}

int flyology_test_file_watch_events_lost(void) {
    return atomic_exchange_explicit(&events_lost_once, 0,
                                    memory_order_relaxed);
}

int flyology_test_file_watch_remove_failure(void) {
    return atomic_exchange_explicit(&remove_failure_once, 0,
                                    memory_order_relaxed);
}

int flyology_test_file_watch_close_failure(void) {
    return atomic_exchange_explicit(&close_failure_once, 0,
                                    memory_order_relaxed);
}
