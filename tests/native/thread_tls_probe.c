#include <stdint.h>

/* Deliberately real pthread-local state, separate from Ada task state. */
static _Thread_local uintptr_t gnatevl_test_tls_value;

uintptr_t gnatevl_test_tls_get(void) {
    return gnatevl_test_tls_value;
}

void gnatevl_test_tls_set(uintptr_t value) {
    gnatevl_test_tls_value = value;
}
