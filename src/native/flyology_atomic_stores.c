/*
 * Release-store compiler-intrinsic leaves only.
 *
 * GNAT 13 documents GCC's generic __atomic_store_n builtin but does not lower
 * an Ada Import (Intrinsic) of it. Ada frontend support arrived in GCC 14 as
 * "ada: Add __atomic_store_n binding to System.Atomic_Primitives", upstream
 * commit 4784601d726e5b70b6c4e050c77749706536ccf3. These fixed-width C leaves
 * keep the memory order compile-time constant and contain no retry or policy.
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
