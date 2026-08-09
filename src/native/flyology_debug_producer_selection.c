/* Copyright (c) 2026 Yurii Rashkovskii */
/* SPDX-License-Identifier: MIT OR Apache-2.0 */

#include <pthread.h>
#include <stdint.h>
#include <string.h>

uint64_t
flyology_debug_native_thread_key(void)
{
    pthread_t self = pthread_self();
    unsigned char bytes[sizeof self];
    uint64_t hash = UINT64_C(14695981039346656037);
    size_t index;

    memcpy(bytes, &self, sizeof bytes);
    for (index = 0; index < sizeof bytes; ++index) {
        hash ^= bytes[index];
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}
