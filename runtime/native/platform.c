#include <sys/mman.h>
#include <stdint.h>

int gnatevl_map_anonymous(void) {
    return MAP_ANONYMOUS;
}

void gnatevl_atomic_store_u32(void *address, uint32_t value, int model) {
    __atomic_store_n((uint32_t *)address, value, model);
}
