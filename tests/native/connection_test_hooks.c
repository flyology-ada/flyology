#include <stdatomic.h>
#include <pthread.h>

enum {
   raw_accept_returned = 13,
   barrier_count = 19
};

static _Atomic int armed[barrier_count];
static _Atomic int reached[barrier_count];
static _Atomic int released[barrier_count];
static _Atomic int fail_next_capacity_release_wake;
static _Atomic int receive_cap;
static _Atomic unsigned receive_calls;
static pthread_mutex_t raw_accept_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t raw_accept_condition = PTHREAD_COND_INITIALIZER;

static int valid_point(int point)
{
   return point >= 0 && point < barrier_count;
}

void flyology_test_connection_barrier_reset(void)
{
   atomic_store_explicit(
     &fail_next_capacity_release_wake, 0, memory_order_seq_cst);
   for (int point = 0; point < barrier_count; ++point) {
      atomic_store_explicit(&armed[point], 0, memory_order_seq_cst);
      atomic_store_explicit(&reached[point], 0, memory_order_seq_cst);
      atomic_store_explicit(&released[point], 1, memory_order_seq_cst);
   }
}

void flyology_test_connection_set_receive_cap(int maximum)
{
   atomic_store_explicit(&receive_calls, 0, memory_order_seq_cst);
   atomic_store_explicit(
     &receive_cap, maximum > 0 ? maximum : 0, memory_order_seq_cst);
}

int flyology_test_connection_receive_limit(int requested)
{
   int maximum = atomic_load_explicit(&receive_cap, memory_order_seq_cst);

   atomic_fetch_add_explicit(&receive_calls, 1, memory_order_seq_cst);
   return maximum > 0 && maximum < requested ? maximum : requested;
}

unsigned flyology_test_connection_receive_calls(void)
{
   return atomic_load_explicit(&receive_calls, memory_order_seq_cst);
}

void flyology_test_connection_barrier_arm(int point)
{
   if (!valid_point(point)) return;
   atomic_store_explicit(&reached[point], 0, memory_order_seq_cst);
   atomic_store_explicit(&released[point], 0, memory_order_seq_cst);
   atomic_store_explicit(&armed[point], 1, memory_order_seq_cst);
}

int flyology_test_connection_barrier_arrive(int point)
{
   if (!valid_point(point) ||
       atomic_load_explicit(&armed[point], memory_order_seq_cst) == 0)
      return 0;
   atomic_store_explicit(&reached[point], 1, memory_order_seq_cst);
   return 1;
}

int flyology_test_connection_barrier_arrive_once(int point)
{
   int expected = 1;

   if (!valid_point(point) ||
       !atomic_compare_exchange_strong_explicit(
          &armed[point], &expected, 0,
          memory_order_seq_cst, memory_order_seq_cst))
      return 0;
   atomic_store_explicit(&reached[point], 1, memory_order_seq_cst);
   return 1;
}

int flyology_test_connection_barrier_reached(int point)
{
   return valid_point(point)
     ? atomic_load_explicit(&reached[point], memory_order_seq_cst) : 0;
}

int flyology_test_connection_barrier_released(int point)
{
   return valid_point(point)
     ? atomic_load_explicit(&released[point], memory_order_seq_cst) : 1;
}

void flyology_test_connection_barrier_release(int point)
{
   if (!valid_point(point)) return;
   atomic_store_explicit(&released[point], 1, memory_order_seq_cst);
   atomic_store_explicit(&armed[point], 0, memory_order_seq_cst);
   if (point == raw_accept_returned) {
      pthread_mutex_lock(&raw_accept_mutex);
      pthread_cond_broadcast(&raw_accept_condition);
      pthread_mutex_unlock(&raw_accept_mutex);
   }
}

void flyology_test_connection_raw_accept_return_barrier(void)
{
   pthread_mutex_lock(&raw_accept_mutex);
   if (atomic_load_explicit(
         &armed[raw_accept_returned], memory_order_seq_cst) != 0) {
      atomic_store_explicit(
        &reached[raw_accept_returned], 1, memory_order_seq_cst);
      while (atomic_load_explicit(
               &released[raw_accept_returned], memory_order_seq_cst) == 0) {
         pthread_cond_wait(&raw_accept_condition, &raw_accept_mutex);
      }
   }
   pthread_mutex_unlock(&raw_accept_mutex);
}

void flyology_test_connection_arm_capacity_release_wake_failure(void)
{
   atomic_store_explicit(
     &fail_next_capacity_release_wake, 1, memory_order_seq_cst);
}

int flyology_test_connection_fail_next_capacity_release_wake(void)
{
   return atomic_exchange_explicit(
     &fail_next_capacity_release_wake, 0, memory_order_seq_cst);
}
