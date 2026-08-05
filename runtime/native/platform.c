#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <sys/mman.h>
#include <sys/socket.h>
#include <pthread.h>
#include <errno.h>
#include <stdint.h>
#include <unistd.h>

#if defined(__linux__)
#include <sched.h>
#include <sys/epoll.h>
#include <sys/syscall.h>
#elif defined(__APPLE__)
#include <mach/mach.h>
#include <mach/thread_policy.h>
#endif

#if defined(__linux__)
static int flyology_linux_selected_file_backend;

/* GNAT 13 and 14 assume a 16 KiB pthread minimum on every Linux target.
   glibc requires 128 KiB on AArch64, so reject-free native task creation
   needs the target value supplied by the active C library. */
size_t flyology_linux_pthread_stack_min(void) {
#if defined(_SC_THREAD_STACK_MIN)
    long value = sysconf(_SC_THREAD_STACK_MIN);

    if (value > 0) {
        return (size_t)value;
    }
#endif
    return (size_t)PTHREAD_STACK_MIN;
}

void flyology_linux_note_file_backend(int backend) {
    __atomic_store_n(&flyology_linux_selected_file_backend, backend,
                     __ATOMIC_RELAXED);
}

int flyology_linux_file_backend(void) {
    return __atomic_load_n(&flyology_linux_selected_file_backend,
                           __ATOMIC_RELAXED);
}

struct flyology_epoll_event {
    uint32_t events;
    int descriptor;
};
_Static_assert(sizeof(struct flyology_epoll_event) == 8,
               "Ada epoll translation record must remain eight bytes");

/* Translate through libc's native struct epoll_event so ABI-dependent
   padding never leaks into Ada.  x86-64 uses a packed 12-byte kernel record;
   AArch64 uses a naturally aligned 16-byte record. */
int flyology_linux_epoll_ctl(int epoll_fd, int operation, int descriptor,
                            uint32_t events) {
    struct epoll_event item = { .events = events };

    item.data.fd = descriptor;
    return epoll_ctl(epoll_fd, operation, descriptor,
                     operation == EPOLL_CTL_DEL ? NULL : &item);
}

int flyology_linux_epoll_wait(int epoll_fd,
                             struct flyology_epoll_event *events,
                             int max_events, int timeout_ms) {
    struct epoll_event native_events[64];
    int count;
    int index;

    if (events == NULL || max_events < 1 || max_events > 64) {
        errno = EINVAL;
        return -1;
    }
    count = epoll_wait(epoll_fd, native_events, max_events, timeout_ms);
    if (count < 0) {
        return -1;
    }
    for (index = 0; index < count; ++index) {
        events[index].events = native_events[index].events;
        events[index].descriptor = native_events[index].data.fd;
    }
    return count;
}

/*
 * Keep Linux syscall-number selection in C, where the target system headers
 * describe the active ABI.  The scheduler and file-engine policy stay in Ada;
 * these wrappers are only a typed bridge for interfaces that glibc does not
 * expose as ordinary functions.  syscall(2) preserves its normal convention:
 * -1 on failure with errno set, and a nonnegative kernel result on success.
 */
long flyology_linux_io_setup(unsigned entries, unsigned long *context) {
    return syscall(SYS_io_setup, entries, context);
}

long flyology_linux_io_destroy(unsigned long context) {
    return syscall(SYS_io_destroy, context);
}

long flyology_linux_io_submit(unsigned long context, long count,
                             void *controls) {
    return syscall(SYS_io_submit, context, count, controls);
}

long flyology_linux_io_cancel(unsigned long context, void *control,
                             void *result) {
    return syscall(SYS_io_cancel, context, control, result);
}

long flyology_linux_io_getevents(unsigned long context, long minimum,
                                long count, void *events, void *timeout) {
    return syscall(SYS_io_getevents, context, minimum, count, events, timeout);
}

long flyology_linux_io_uring_setup(unsigned entries, void *parameters) {
#if defined(FLYOLOGY_TEST_DENY_IO_URING)
    (void)entries;
    (void)parameters;
    errno = EPERM;
    return -1;
#else
    return syscall(SYS_io_uring_setup, entries, parameters);
#endif
}

long flyology_linux_io_uring_enter(int descriptor, unsigned to_submit,
                                  unsigned minimum, unsigned flags,
                                  void *signal_mask, size_t signal_size) {
    return syscall(SYS_io_uring_enter, descriptor, to_submit, minimum, flags,
                   signal_mask, signal_size);
}

long flyology_linux_io_uring_register(int descriptor, unsigned opcode,
                                     void *argument, unsigned count) {
    return syscall(SYS_io_uring_register, descriptor, opcode, argument, count);
}
#endif

#if !defined(__linux__)
int flyology_linux_file_backend(void) {
    return 0;
}

#endif

#define FLYOLOGY_PLACEMENT_STRICT 1
#define FLYOLOGY_PLACEMENT_ADVISORY 2
#define FLYOLOGY_PLACEMENT_UNSUPPORTED (-1)
#define FLYOLOGY_PLACEMENT_INVALID (-2)

#if defined(__linux__)
static cpu_set_t flyology_initial_cpu_mask;
static int flyology_initial_cpu_mask_valid;
#endif
static pthread_once_t flyology_placement_once = PTHREAD_ONCE_INIT;
static int flyology_placement_initialization_result;

/*
 * Capture the Linux process leader's CPU allowance. Unlike pthread_self(),
 * getpid() continues to name the leader when a placement request originates
 * on an already-narrowed native or event-loop thread. The scheduler owns
 * placement policy; these helpers only bridge macro-only OS interfaces and
 * verify kernel state.
 */
static void flyology_thread_placement_initialize_once(void) {
#if defined(__linux__)
    int result = sched_getaffinity(getpid(), sizeof(flyology_initial_cpu_mask),
                                   &flyology_initial_cpu_mask);
    flyology_initial_cpu_mask_valid = result == 0;
    flyology_placement_initialization_result = result == 0 ? 0 : errno;
#endif
}

int flyology_thread_placement_initialize(void) {
    int result = pthread_once(&flyology_placement_once,
                              flyology_thread_placement_initialize_once);
    return result == 0 ? flyology_placement_initialization_result : result;
}

static int flyology_thread_placement_platform_ready(void) {
    return flyology_thread_placement_initialize() == 0;
}

int flyology_thread_placement_supported(int mode) {
    if (!flyology_thread_placement_platform_ready()) {
        return 0;
    }
#if defined(__linux__)
    return mode == FLYOLOGY_PLACEMENT_STRICT &&
           flyology_initial_cpu_mask_valid;
#elif defined(__APPLE__)
#if defined(__aarch64__) || defined(__arm64__)
    (void)mode;
    return 0;
#else
    return mode == FLYOLOGY_PLACEMENT_ADVISORY;
#endif
#else
    (void)mode;
    return 0;
#endif
}

int flyology_thread_placement_validate(int mode, int value) {
    if (!flyology_thread_placement_supported(mode)) {
        return FLYOLOGY_PLACEMENT_UNSUPPORTED;
    }
#if defined(__linux__)
    if (!flyology_initial_cpu_mask_valid || value < 0 || value >= CPU_SETSIZE ||
        !CPU_ISSET(value, &flyology_initial_cpu_mask)) {
        return FLYOLOGY_PLACEMENT_INVALID;
    }
    return 0;
#elif defined(__APPLE__)
    return value > 0 ? 0 : FLYOLOGY_PLACEMENT_INVALID;
#endif
}

int flyology_thread_placement_apply(int mode, int value) {
    int valid = flyology_thread_placement_validate(mode, value);

    if (valid != 0) {
        return valid;
    }
#if defined(__linux__)
    cpu_set_t requested;
    cpu_set_t effective;
    int result;

    CPU_ZERO(&requested);
    CPU_SET(value, &requested);
    result = pthread_setaffinity_np(pthread_self(), sizeof(requested),
                                    &requested);
    if (result != 0) {
        return result;
    }
    result = pthread_getaffinity_np(pthread_self(), sizeof(effective),
                                    &effective);
    if (result != 0) {
        return result;
    }
    if (CPU_COUNT(&effective) != 1 || !CPU_ISSET(value, &effective)) {
        return EIO;
    }
    return 0;
#elif defined(__APPLE__)
    thread_affinity_policy_data_t requested = { value };
    thread_port_t thread = pthread_mach_thread_np(pthread_self());
    kern_return_t result;

    result = thread_policy_set(thread, THREAD_AFFINITY_POLICY,
                               (thread_policy_t)&requested,
                               THREAD_AFFINITY_POLICY_COUNT);
    /* Darwin offers no supported read-back or physical-CPU guarantee for
       this hint. Applied means the kernel accepted thread_policy_set. */
    return result == KERN_SUCCESS ? 0 : (int)result;
#endif
}

int flyology_thread_current_processor(void) {
#if defined(__linux__)
    return sched_getcpu();
#else
    /* Darwin exposes no stable public physical-CPU identity contract. */
    return -1;
#endif
}

static uint32_t *flyology_fork_child_flag;

static void flyology_mark_fork_child(void) {
    __atomic_store_n(flyology_fork_child_flag, 1, __ATOMIC_RELAXED);
}

int flyology_install_fork_guard(void *flag) {
    if (flag == NULL || flyology_fork_child_flag != NULL) {
        return -1;
    }
    flyology_fork_child_flag = (uint32_t *)flag;
    return pthread_atfork(NULL, NULL, flyology_mark_fork_child);
}

int flyology_in_fork_child(void) {
    return flyology_fork_child_flag != NULL &&
           __atomic_load_n(flyology_fork_child_flag, __ATOMIC_RELAXED) != 0;
}

#define FLYOLOGY_FAULT_ACCEPT_CONNECTION_ABORTED 20
#define FLYOLOGY_FAULT_ACCEPT_PROTOCOL_ERROR 21
#define FLYOLOGY_FAULT_ACCEPT_PROCESS_LIMIT 22
#define FLYOLOGY_FAULT_ACCEPT_SYSTEM_LIMIT 23
#define FLYOLOGY_FAULT_ACCEPT_BAD_DESCRIPTOR 24
#define FLYOLOGY_FAULT_STRUCTURED_LISTENER_CLOSE 25

#ifdef FLYOLOGY_TEST_FAULTS
#include <stdatomic.h>

#define FLYOLOGY_FAULT_POINT_COUNT 34
#define FLYOLOGY_FILE_CANCEL_BACKENDS 3
#define FLYOLOGY_FILE_CANCEL_DISPOSITIONS 4

struct flyology_fault_plan {
    atomic_uint calls;
    atomic_uint first;
    atomic_uint count;
};

static struct flyology_fault_plan
    flyology_faults[FLYOLOGY_FAULT_POINT_COUNT + 1];
static atomic_uint flyology_final_reap_state;
static atomic_uint flyology_file_cancel_counts
    [FLYOLOGY_FILE_CANCEL_BACKENDS + 1]
    [FLYOLOGY_FILE_CANCEL_DISPOSITIONS + 1][2];
static atomic_uint flyology_uring_identity_counts[2];
static atomic_uint flyology_uring_admin_completions;
static atomic_uint flyology_uring_cq_capacity;

void flyology_test_note_uring_cq_capacity(unsigned capacity) {
    atomic_store_explicit(&flyology_uring_cq_capacity, capacity,
                          memory_order_relaxed);
}

unsigned flyology_test_uring_cq_capacity(void) {
    return atomic_load_explicit(&flyology_uring_cq_capacity,
                                memory_order_relaxed);
}

void flyology_test_note_uring_identity(int reused) {
    atomic_fetch_add_explicit(&flyology_uring_identity_counts[reused != 0], 1,
                              memory_order_relaxed);
}

unsigned flyology_test_uring_identity_count(int reused) {
    return atomic_load_explicit(&flyology_uring_identity_counts[reused != 0],
                                memory_order_relaxed);
}

void flyology_test_note_uring_admin_complete(void) {
    atomic_fetch_add_explicit(&flyology_uring_admin_completions, 1,
                              memory_order_relaxed);
}

unsigned flyology_test_uring_admin_complete_count(void) {
    return atomic_load_explicit(&flyology_uring_admin_completions,
                                memory_order_relaxed);
}

void flyology_test_note_file_cancel(int backend, int disposition,
                                    int terminal) {
    if (backend < 1 || backend > FLYOLOGY_FILE_CANCEL_BACKENDS ||
        disposition < 1 ||
        disposition > FLYOLOGY_FILE_CANCEL_DISPOSITIONS) {
        return;
    }
    atomic_fetch_add_explicit(
        &flyology_file_cancel_counts[backend][disposition][terminal != 0], 1,
        memory_order_relaxed);
}

unsigned flyology_test_file_cancel_count(int backend, int disposition,
                                         int terminal) {
    if (backend < 1 || backend > FLYOLOGY_FILE_CANCEL_BACKENDS ||
        disposition < 1 ||
        disposition > FLYOLOGY_FILE_CANCEL_DISPOSITIONS) {
        return 0;
    }
    return atomic_load_explicit(
        &flyology_file_cancel_counts[backend][disposition][terminal != 0],
        memory_order_relaxed);
}

int flyology_test_faults_enabled(void) {
    return 1;
}

void flyology_test_fault_reset(void) {
    unsigned point;
    unsigned backend;
    unsigned disposition;

    for (point = 1; point <= FLYOLOGY_FAULT_POINT_COUNT; ++point) {
        atomic_store_explicit(&flyology_faults[point].calls, 0,
                              memory_order_relaxed);
        atomic_store_explicit(&flyology_faults[point].first, 0,
                              memory_order_relaxed);
        atomic_store_explicit(&flyology_faults[point].count, 0,
                              memory_order_release);
    }
    atomic_store_explicit(&flyology_final_reap_state, 0,
                          memory_order_release);
    for (backend = 1; backend <= FLYOLOGY_FILE_CANCEL_BACKENDS; ++backend) {
        for (disposition = 1;
             disposition <= FLYOLOGY_FILE_CANCEL_DISPOSITIONS;
             ++disposition) {
            atomic_store_explicit(
                &flyology_file_cancel_counts[backend][disposition][0], 0,
                memory_order_relaxed);
            atomic_store_explicit(
                &flyology_file_cancel_counts[backend][disposition][1], 0,
                memory_order_relaxed);
        }
    }
    atomic_store_explicit(&flyology_uring_identity_counts[0], 0,
                          memory_order_relaxed);
    atomic_store_explicit(&flyology_uring_identity_counts[1], 0,
                          memory_order_relaxed);
    atomic_store_explicit(&flyology_uring_admin_completions, 0,
                          memory_order_relaxed);
}

int flyology_test_fault_arm(int point, unsigned first, unsigned count) {
    if (point < 1 || point > FLYOLOGY_FAULT_POINT_COUNT) {
        return -1;
    }
    atomic_store_explicit(&flyology_faults[point].calls, 0,
                          memory_order_relaxed);
    atomic_store_explicit(&flyology_faults[point].first, first,
                          memory_order_relaxed);
    atomic_store_explicit(&flyology_faults[point].count, count,
                          memory_order_release);
    return 0;
}

int flyology_test_fault_disarm(int point) {
    if (point < 1 || point > FLYOLOGY_FAULT_POINT_COUNT) {
        return -1;
    }
    atomic_store_explicit(&flyology_faults[point].count, 0,
                          memory_order_release);
    return 0;
}

unsigned flyology_test_fault_calls(int point) {
    if (point < 1 || point > FLYOLOGY_FAULT_POINT_COUNT) {
        return 0;
    }
    return atomic_load_explicit(&flyology_faults[point].calls,
                                memory_order_relaxed);
}

int flyology_test_fault_hit(int point) {
    struct flyology_fault_plan *plan;
    unsigned call;
    unsigned first;
    unsigned count;

    if (point < 1 || point > FLYOLOGY_FAULT_POINT_COUNT) {
        return 0;
    }
    plan = &flyology_faults[point];
    call = atomic_fetch_add_explicit(&plan->calls, 1,
                                     memory_order_relaxed);
    count = atomic_load_explicit(&plan->count, memory_order_acquire);
    if (count == 0) {
        return 0;
    }
    first = atomic_load_explicit(&plan->first, memory_order_relaxed);
    return call >= first && call - first < count;
}

int flyology_test_pause_final_reaper(void) {
    atomic_store_explicit(&flyology_final_reap_state, 1,
                          memory_order_release);
    for (unsigned attempt = 0; attempt < 1000; ++attempt) {
        if (atomic_load_explicit(&flyology_final_reap_state,
                                 memory_order_acquire) == 2) {
            return 0;
        }
        usleep(1000);
    }
    return -1;
}

void flyology_test_release_final_reaper(void) {
    if (atomic_load_explicit(&flyology_final_reap_state,
                             memory_order_acquire) == 1) {
        atomic_store_explicit(&flyology_final_reap_state, 2,
                              memory_order_release);
    }
}
#else
void flyology_test_note_uring_identity(int reused) {
    (void)reused;
}

unsigned flyology_test_uring_identity_count(int reused) {
    (void)reused;
    return 0;
}

void flyology_test_note_uring_admin_complete(void) {
}

unsigned flyology_test_uring_admin_complete_count(void) {
    return 0;
}

void flyology_test_note_file_cancel(int backend, int disposition,
                                    int terminal) {
    (void)backend;
    (void)disposition;
    (void)terminal;
}

unsigned flyology_test_file_cancel_count(int backend, int disposition,
                                         int terminal) {
    (void)backend;
    (void)disposition;
    (void)terminal;
    return 0;
}

int flyology_test_faults_enabled(void) {
    return 0;
}

void flyology_test_fault_reset(void) {
}

int flyology_test_fault_arm(int point, unsigned first, unsigned count) {
    (void)point;
    (void)first;
    (void)count;
    return -1;
}

int flyology_test_fault_disarm(int point) {
    (void)point;
    return -1;
}

unsigned flyology_test_fault_calls(int point) {
    (void)point;
    return 0;
}

int flyology_test_fault_hit(int point) {
    (void)point;
    return 0;
}
#endif

/* Keep errno values that GNAT's generated OS constants do not expose in the
   host-header bridge.  -1 denotes an unavailable condition and cannot collide
   with errno captured after a failed accept. */
int flyology_errno_connection_aborted(void) {
#ifdef ECONNABORTED
    return ECONNABORTED;
#else
    return -1;
#endif
}

int flyology_errno_protocol_error(void) {
#ifdef EPROTO
    return EPROTO;
#else
    return -1;
#endif
}

int flyology_errno_process_file_limit(void) {
#ifdef EMFILE
    return EMFILE;
#else
    return -1;
#endif
}

int flyology_errno_system_file_limit(void) {
#ifdef ENFILE
    return ENFILE;
#else
    return -1;
#endif
}

/* Keep listener close injection at the syscall boundary. Production builds
   contain one direct close(2). Fault-enabled tests report an error after a
   successful close so cleanup must not retry a consumed descriptor number. */
int flyology_structured_listener_close(int descriptor) {
#ifdef FLYOLOGY_TEST_FAULTS
    int inject_failure = flyology_test_fault_hit(
        FLYOLOGY_FAULT_STRUCTURED_LISTENER_CLOSE);
    int result = close(descriptor);
    if (inject_failure && result == 0) {
        errno = EIO;
        return -1;
    }
    return result;
#else
    return close(descriptor);
#endif
}

/* The production path remains one direct accept call.  Deterministic errno
   injection exists only in explicitly fault-enabled test runtimes. */
int flyology_accept(int socket, void *address, void *length) {
#ifdef FLYOLOGY_TEST_FAULTS
    if (flyology_test_fault_hit(
            FLYOLOGY_FAULT_ACCEPT_CONNECTION_ABORTED)) {
        errno = ECONNABORTED;
        return -1;
    }
    if (flyology_test_fault_hit(FLYOLOGY_FAULT_ACCEPT_PROTOCOL_ERROR)) {
        errno = EPROTO;
        return -1;
    }
    if (flyology_test_fault_hit(FLYOLOGY_FAULT_ACCEPT_PROCESS_LIMIT)) {
        errno = EMFILE;
        return -1;
    }
    if (flyology_test_fault_hit(FLYOLOGY_FAULT_ACCEPT_SYSTEM_LIMIT)) {
        errno = ENFILE;
        return -1;
    }
    if (flyology_test_fault_hit(FLYOLOGY_FAULT_ACCEPT_BAD_DESCRIPTOR)) {
        errno = EBADF;
        return -1;
    }
#endif
    return accept(socket, (struct sockaddr *)address, (socklen_t *)length);
}

int flyology_map_anonymous(void) {
    return MAP_ANONYMOUS;
}

/*
 * Stack-arena policy lives in Ada. These wrappers provide only the two
 * process primitives which are awkward to represent portably in the runtime
 * sources: a statically initialized pthread mutex and the host's page-discard
 * advice value. A native-only program never calls either function.
 */
static pthread_mutex_t flyology_stack_pool_mutex = PTHREAD_MUTEX_INITIALIZER;

int flyology_stack_pool_lock(void) {
    return pthread_mutex_lock(&flyology_stack_pool_mutex);
}

int flyology_stack_pool_unlock(void) {
    return pthread_mutex_unlock(&flyology_stack_pool_mutex);
}

int flyology_discard_pages(void *address, size_t length) {
    return madvise(address, length, MADV_DONTNEED);
}

int flyology_cold_pages_supported(void) {
#if defined(__linux__) && defined(MADV_COLD)
    return madvise(NULL, 0, MADV_COLD) == 0;
#else
    return 0;
#endif
}

int flyology_pageout_pages_supported(void) {
#if defined(__linux__) && defined(MADV_PAGEOUT)
    return madvise(NULL, 0, MADV_PAGEOUT) == 0;
#else
    return 0;
#endif
}

int flyology_pageout_pages(void *address, size_t length) {
#if defined(__linux__) && defined(MADV_PAGEOUT)
    return madvise(address, length, MADV_PAGEOUT) == 0 ? 1 : -1;
#else
    (void)address;
    (void)length;
    return 0;
#endif
}

int flyology_cold_pages(void *address, size_t length) {
#if defined(__linux__) && defined(MADV_COLD)
    return madvise(address, length, MADV_COLD) == 0 ? 1 : -1;
#else
    (void)address;
    (void)length;
    return 0;
#endif
}

void flyology_atomic_store_u32(void *address, uint32_t value, int model) {
    __atomic_store_n((uint32_t *)address, value, model);
}
