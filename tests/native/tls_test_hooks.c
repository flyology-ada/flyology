#include <stdatomic.h>

/* Test-only barriers that widen the TLS ownership-transfer window in
 * Flyology.IO.TLS.Take. They exist only when the library is compiled with
 * FLYOLOGY_TLS_TEST_HOOKS. */

enum {
   barrier_count = 2
};

static _Atomic int armed[barrier_count];
static _Atomic int reached[barrier_count];
static _Atomic int released[barrier_count];

static int valid_point(int point)
{
   return point >= 0 && point < barrier_count;
}

void flyology_test_tls_barrier_reset(void)
{
   for (int point = 0; point < barrier_count; ++point) {
      atomic_store_explicit(&armed[point], 0, memory_order_seq_cst);
      atomic_store_explicit(&reached[point], 0, memory_order_seq_cst);
      atomic_store_explicit(&released[point], 1, memory_order_seq_cst);
   }
}

void flyology_test_tls_barrier_arm(int point)
{
   if (!valid_point(point)) return;
   atomic_store_explicit(&reached[point], 0, memory_order_seq_cst);
   atomic_store_explicit(&released[point], 0, memory_order_seq_cst);
   atomic_store_explicit(&armed[point], 1, memory_order_seq_cst);
}

int flyology_test_tls_barrier_arrive(int point)
{
   if (!valid_point(point) ||
       atomic_load_explicit(&armed[point], memory_order_seq_cst) == 0)
      return 0;
   atomic_store_explicit(&reached[point], 1, memory_order_seq_cst);
   return 1;
}

int flyology_test_tls_barrier_reached(int point)
{
   return valid_point(point)
     ? atomic_load_explicit(&reached[point], memory_order_seq_cst) : 0;
}

int flyology_test_tls_barrier_released(int point)
{
   return valid_point(point)
     ? atomic_load_explicit(&released[point], memory_order_seq_cst) : 1;
}

void flyology_test_tls_barrier_release(int point)
{
   if (!valid_point(point)) return;
   atomic_store_explicit(&released[point], 1, memory_order_seq_cst);
   atomic_store_explicit(&armed[point], 0, memory_order_seq_cst);
}
