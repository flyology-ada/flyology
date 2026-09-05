/*
 * Release-store compiler-intrinsic leaves only.
 *
 * GNAT 13 does not lower an Ada Import (Intrinsic) of GCC's generic
 * __atomic_store_n builtin. Although its System.Atomic_Primitives binding was
 * added during GCC 14 development, the supported stock GNAT 14 toolchains do
 * not provide the usable binding. These fixed-width C leaves retain the
 * workaround through GNAT 14, keep the memory order compile-time constant,
 * and contain no retry or policy.
 *
 * https://gcc.gnu.org/pipermail/gcc-cvs/2024-January/396280.html
 */

#include <stdint.h>

void flyology_atomic_store_release_u32(uint32_t *address, uint32_t value)
{
    __atomic_store_n(address, value, __ATOMIC_RELEASE);
}

void flyology_atomic_store_release_u64(uint64_t *address, uint64_t value)
{
    __atomic_store_n(address, value, __ATOMIC_RELEASE);
}
