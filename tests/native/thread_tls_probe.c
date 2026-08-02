#include <stdint.h>

/* Deliberately real pthread-local state, separate from Ada task state. */
static _Thread_local uintptr_t flyology_test_tls_value;

uintptr_t flyology_test_tls_get(void) {
    return flyology_test_tls_value;
}

void flyology_test_tls_set(uintptr_t value) {
    flyology_test_tls_value = value;
}
