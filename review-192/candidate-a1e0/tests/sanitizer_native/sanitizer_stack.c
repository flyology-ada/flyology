#include <stddef.h>
#include <stdint.h>

#if defined(__GNUC__) || defined(__clang__)
#define FLYOLOGY_NOINLINE __attribute__((noinline))
#else
#define FLYOLOGY_NOINLINE
#endif

FLYOLOGY_NOINLINE
unsigned flyology_sanitizer_touch_stack(unsigned seed, unsigned depth) {
    volatile unsigned char frame[257];
    unsigned result = seed;
    size_t index;

    for (index = 0; index < sizeof(frame); ++index) {
        frame[index] = (unsigned char)(seed + index);
        result = result * 33u + frame[index];
    }
    if (depth != 0) {
        result ^= flyology_sanitizer_touch_stack(result, depth - 1);
    }
    return result ^ frame[seed % sizeof(frame)];
}

FLYOLOGY_NOINLINE
void flyology_sanitizer_trigger_stack_violation(unsigned index) {
    volatile unsigned char frame[8] = {0};

    /* The sanitizer subprocess passes 16. Keeping the index opaque to the
       compiler makes this a runtime ASan report rather than a compile-time
       diagnostic or an optimized-away store. */
    frame[index] = 42;
}
