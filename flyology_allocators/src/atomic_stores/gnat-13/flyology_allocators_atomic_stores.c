/*
 * Standalone allocator release-store compiler-intrinsic leaf only.
 *
 * GNAT 13 documents GCC's generic __atomic_store_n builtin but does not lower
 * an Ada Import (Intrinsic) of it. Ada frontend support arrived in GCC 14 as
 * "ada: Add __atomic_store_n binding to System.Atomic_Primitives", upstream
 * commit 4784601d726e5b70b6c4e050c77749706536ccf3. This fixed-width C leaf keeps
 * the memory order compile-time constant and contains no retry or policy.
 *
 * https://gcc.gnu.org/pipermail/gcc-cvs/2024-January/396280.html
 */

#include <stdint.h>

void flyology_allocators_atomic_store_release_u32(uint32_t *address, uint32_t value)
{
    __atomic_store_n(address, value, __ATOMIC_RELEASE);
}
