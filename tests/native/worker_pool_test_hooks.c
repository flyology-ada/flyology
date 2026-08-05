#include <stdatomic.h>

static _Atomic int activation_failure_ordinal;
static _Atomic int activation_count;
static _Atomic int shutdown_barrier_armed;
static _Atomic int shutdown_barrier_reached;
static _Atomic int shutdown_barrier_released;
static _Atomic int native_executor_cancellation_failure;
static _Atomic int native_executor_consume_failure;
static _Atomic int native_executor_completion_wake;
static _Atomic int token_cleanup_barrier_armed;
static _Atomic int token_cleanup_barrier_reached;
static _Atomic int token_cleanup_barrier_released;
static _Atomic int token_cleanup_outstanding;

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
   atomic_store_explicit(&native_executor_cancellation_failure, 0,
                         memory_order_seq_cst);
   atomic_store_explicit(&native_executor_consume_failure, 0,
                         memory_order_seq_cst);
   atomic_store_explicit(&native_executor_completion_wake, 0,
                         memory_order_seq_cst);
   atomic_store_explicit(&token_cleanup_barrier_armed, 0,
                         memory_order_seq_cst);
   atomic_store_explicit(&token_cleanup_barrier_reached, 0,
                         memory_order_seq_cst);
   atomic_store_explicit(&token_cleanup_barrier_released, 1,
                         memory_order_seq_cst);
   atomic_store_explicit(&token_cleanup_outstanding, 0,
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

void flyology_test_worker_native_executor_cancellation_fail_once(void)
{
   atomic_store_explicit(&native_executor_cancellation_failure, 1,
                         memory_order_seq_cst);
}

void flyology_test_worker_native_executor_cancellation_failures(int count)
{
   atomic_store_explicit(&native_executor_cancellation_failure, count,
                         memory_order_seq_cst);
}

int flyology_test_worker_native_executor_cancellation_failure(void)
{
   int remaining = atomic_load_explicit(&native_executor_cancellation_failure,
                                        memory_order_seq_cst);
   while (remaining > 0) {
      if (atomic_compare_exchange_weak_explicit(
             &native_executor_cancellation_failure, &remaining, remaining - 1,
             memory_order_seq_cst, memory_order_seq_cst))
         return 1;
   }
   return 0;
}

int flyology_test_worker_native_executor_cancellation_failures_remaining(void)
{
   return atomic_load_explicit(&native_executor_cancellation_failure,
                               memory_order_seq_cst);
}

void flyology_test_worker_native_executor_consume_fail_once(void)
{
   atomic_store_explicit(&native_executor_consume_failure, 1,
                         memory_order_seq_cst);
}

int flyology_test_worker_native_executor_consume_failure(void)
{
   return atomic_exchange_explicit(&native_executor_consume_failure, 0,
                                   memory_order_seq_cst);
}

void flyology_test_worker_native_executor_completion_wake_once(void)
{
   atomic_store_explicit(&native_executor_completion_wake, 1,
                         memory_order_seq_cst);
}

int flyology_test_worker_native_executor_completion_wake(void)
{
   return atomic_exchange_explicit(&native_executor_completion_wake, 0,
                                   memory_order_seq_cst);
}

void flyology_test_worker_token_cleanup_barrier_arm(void)
{
   atomic_store_explicit(&token_cleanup_barrier_reached, 0,
                         memory_order_seq_cst);
   atomic_store_explicit(&token_cleanup_barrier_released, 0,
                         memory_order_seq_cst);
   atomic_store_explicit(&token_cleanup_barrier_armed, 1,
                         memory_order_seq_cst);
}

int flyology_test_worker_token_cleanup_barrier_arrive(void)
{
   if (atomic_exchange_explicit(&token_cleanup_barrier_armed, 0,
                                memory_order_seq_cst) == 0)
      return 0;
   atomic_store_explicit(&token_cleanup_barrier_reached, 1,
                         memory_order_seq_cst);
   return 1;
}

int flyology_test_worker_token_cleanup_barrier_reached(void)
{
   return atomic_load_explicit(&token_cleanup_barrier_reached,
                               memory_order_seq_cst);
}

int flyology_test_worker_token_cleanup_barrier_released(void)
{
   return atomic_load_explicit(&token_cleanup_barrier_released,
                               memory_order_seq_cst);
}

void flyology_test_worker_token_cleanup_barrier_release(void)
{
   atomic_store_explicit(&token_cleanup_barrier_released, 1,
                         memory_order_seq_cst);
   atomic_store_explicit(&token_cleanup_barrier_armed, 0,
                         memory_order_seq_cst);
}

void flyology_test_worker_token_cleanup_acquire(void)
{
   atomic_fetch_add_explicit(&token_cleanup_outstanding, 1,
                             memory_order_seq_cst);
}

void flyology_test_worker_token_cleanup_release(void)
{
   atomic_fetch_sub_explicit(&token_cleanup_outstanding, 1,
                             memory_order_seq_cst);
}

int flyology_test_worker_token_cleanup_outstanding(void)
{
   return atomic_load_explicit(&token_cleanup_outstanding,
                               memory_order_seq_cst);
}
