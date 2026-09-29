/* Exercise the fixed-width C ABI and release/acquire publication behavior. */

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>

void flyology_atomic_store_release_u32(uint32_t *, uint32_t);
void flyology_atomic_store_release_u64(uint64_t *, uint64_t);

enum { ITERATIONS = 10000 };

struct u32_exchange {
    uint32_t payload;
    uint32_t ready;
    uint32_t acknowledged;
};

struct u64_exchange {
    uint64_t payload;
    uint64_t ready;
    uint64_t acknowledged;
};

static struct u32_exchange u32_state;
static struct u64_exchange u64_state;

static void *publish(void *unused)
{
    (void)unused;
    for (uint32_t sequence = 1; sequence <= ITERATIONS; ++sequence) {
        while (__atomic_load_n(&u32_state.acknowledged, __ATOMIC_ACQUIRE) != sequence - 1)
            ;
        u32_state.payload = sequence ^ UINT32_C(0xa5a55a5a);
        flyology_atomic_store_release_u32(&u32_state.ready, sequence);
    }
    for (uint64_t sequence = 1; sequence <= ITERATIONS; ++sequence) {
        while (__atomic_load_n(&u64_state.acknowledged, __ATOMIC_ACQUIRE) != sequence - 1)
            ;
        u64_state.payload = sequence ^ UINT64_C(0xa5a55a5af0f00f0f);
        flyology_atomic_store_release_u64(&u64_state.ready, sequence);
    }
    return NULL;
}

int main(void)
{
    pthread_t producer;

    _Static_assert(sizeof(uint32_t) == 4, "uint32_t ABI width");
    _Static_assert(sizeof(uint64_t) == 8, "uint64_t ABI width");

    if (pthread_create(&producer, NULL, publish, NULL) != 0)
        return 1;

    for (uint32_t sequence = 1; sequence <= ITERATIONS; ++sequence) {
        while (__atomic_load_n(&u32_state.ready, __ATOMIC_ACQUIRE) != sequence)
            ;
        if (u32_state.payload != (sequence ^ UINT32_C(0xa5a55a5a)))
            return 1;
        flyology_atomic_store_release_u32(&u32_state.acknowledged, sequence);
    }
    for (uint64_t sequence = 1; sequence <= ITERATIONS; ++sequence) {
        while (__atomic_load_n(&u64_state.ready, __ATOMIC_ACQUIRE) != sequence)
            ;
        if (u64_state.payload != (sequence ^ UINT64_C(0xa5a55a5af0f00f0f)))
            return 1;
        flyology_atomic_store_release_u64(&u64_state.acknowledged, sequence);
    }
    if (pthread_join(producer, NULL) != 0)
        return 1;

    puts("release-store C ABI and publication behavior: PASS");
    return 0;
}
