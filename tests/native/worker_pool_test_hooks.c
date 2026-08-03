#include <stdatomic.h>

static _Atomic int activation_failure_ordinal;
static _Atomic int activation_count;
static _Atomic int shutdown_barrier_armed;
static _Atomic int shutdown_barrier_reached;
static _Atomic int shutdown_barrier_released;

void flyology_test_worker_pool_reset(void)
{
   atomic_store_explicit(&activation_failure_ordinal, 0,
                         memory_order_seq_cst);
   atomic_store_explicit(&activation_count, 0, memory_order_seq_cst);
   atomic_store_explicit(&shutdown_barrier_armed, 0, memory_order_seq_cst);
   atomic_store_explicit(&shutdown_barrier_reached, 0,
                         memory_order_seq_cst);
   atomic_store_explicit(&shutdown_barrier_released, 1,
                         memory_order_seq_cst);
}

void flyology_test_worker_activation_fail_at(int ordinal)
{
   atomic_store_explicit(&activation_count, 0, memory_order_seq_cst);
   atomic_store_explicit(&activation_failure_ordinal, ordinal,
                         memory_order_seq_cst);
}

int flyology_test_worker_activation_failure(void)
{
   int ordinal = atomic_fetch_add_explicit(&activation_count, 1,
                                           memory_order_seq_cst) + 1;
   return ordinal == atomic_load_explicit(&activation_failure_ordinal,
                                          memory_order_seq_cst);
}

void flyology_test_worker_shutdown_barrier_arm(void)
{
   atomic_store_explicit(&shutdown_barrier_reached, 0,
                         memory_order_seq_cst);
   atomic_store_explicit(&shutdown_barrier_released, 0,
                         memory_order_seq_cst);
   atomic_store_explicit(&shutdown_barrier_armed, 1,
                         memory_order_seq_cst);
}

int flyology_test_worker_shutdown_barrier_arrive(void)
{
   if (atomic_load_explicit(&shutdown_barrier_armed,
                            memory_order_seq_cst) == 0)
      return 0;
   atomic_store_explicit(&shutdown_barrier_reached, 1,
                         memory_order_seq_cst);
   return 1;
}

int flyology_test_worker_shutdown_barrier_reached(void)
{
   return atomic_load_explicit(&shutdown_barrier_reached,
                               memory_order_seq_cst);
}

int flyology_test_worker_shutdown_barrier_released(void)
{
   return atomic_load_explicit(&shutdown_barrier_released,
                               memory_order_seq_cst);
}

void flyology_test_worker_shutdown_barrier_release(void)
{
   atomic_store_explicit(&shutdown_barrier_released, 1,
                         memory_order_seq_cst);
   atomic_store_explicit(&shutdown_barrier_armed, 0,
                         memory_order_seq_cst);
}
