/* Copyright (c) 2026 Yurii Rashkovskii
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */

/* Leaf platform values and mechanisms for flyology_bench.
 *
 * Everything this crate measures is decided in Ada. This file holds only the
 * three things Ada cannot reach on its own:
 *
 *   1. Preprocessor constants (open and flock flags, clock identifiers,
 *      system-call numbers, perf ioctl requests, limits, storage sizes).
 *   2. Entry points that exist on one platform only, so a single Ada body
 *      importing them directly would not link on the other. Each is a bare
 *      call with no retry, classification, or bookkeeping of its own.
 *   3. Registration of a thread-exit callback, which POSIX exposes only
 *      through pthread_key_create and a key type with no portable Ada
 *      representation.
 *
 * The stubs a platform does not implement report ENOSYS. Ada never calls
 * them there: it selects by flyology_bench_platform_os and takes its own
 * path, so the stubs exist for linking rather than for use.
 */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <errno.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

#if defined(__APPLE__)
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/processor_info.h>
#include <mach/thread_policy.h>
#elif defined(__linux__)
#include <linux/perf_event.h>
#include <sched.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#else
#error "flyology_bench supports Darwin and Linux"
#endif

/* GCC 13 through 15 do not expose SIZEOF_tv_nsec in System.OS_Constants.
 * Ada therefore derives the field width from Interfaces.C.long. Fail the
 * build if a supported target's headers give timespec.tv_nsec another type.
 */
_Static_assert(
    _Generic(((struct timespec *)0)->tv_nsec, long: 1, default: 0),
    "struct timespec.tv_nsec must have C long type");

/* ------------------------------------------------------------------ */
/* Platform identity.                                                  */
/* ------------------------------------------------------------------ */

#if defined(__APPLE__)
const int flyology_bench_platform_os = 1;
#else
const int flyology_bench_platform_os = 2;
#endif

#if defined(__aarch64__) || defined(__arm64__)
const int flyology_bench_platform_architecture = 1;
#elif defined(__x86_64__)
const int flyology_bench_platform_architecture = 2;
#else
const int flyology_bench_platform_architecture = 0;
#endif

/* ------------------------------------------------------------------ */
/* Header constants.                                                   */
/* ------------------------------------------------------------------ */

const int flyology_bench_o_rdwr = O_RDWR;
const int flyology_bench_o_creat = O_CREAT;
const int flyology_bench_o_cloexec = O_CLOEXEC;
const int flyology_bench_o_nofollow = O_NOFOLLOW;

const int flyology_bench_lock_shared = LOCK_SH;
const int flyology_bench_lock_exclusive = LOCK_EX;
const int flyology_bench_lock_nonblocking = LOCK_NB;
const int flyology_bench_lock_unlock = LOCK_UN;

const int flyology_bench_sc_pagesize = _SC_PAGESIZE;

/* The first logical CPU number the placement call cannot name. Darwin's
 * affinity tag is an int; Linux bounds the mask by CPU_SETSIZE.
 */
#if defined(__APPLE__)
const int flyology_bench_cpu_limit = INT_MAX;
#else
const int flyology_bench_cpu_limit = CPU_SETSIZE;
#endif

/* Linux counts monotonic nanoseconds through clock_gettime; Darwin reads
 * Mach ticks instead, so it publishes no clock identifier.
 */
#if defined(__APPLE__)
const int flyology_bench_monotonic_clock = -1;
#else
const int flyology_bench_monotonic_clock = CLOCK_MONOTONIC_RAW;
#endif

#if defined(__linux__)
const long flyology_bench_perf_event_open_call = __NR_perf_event_open;
const unsigned long flyology_bench_perf_enable_request = PERF_EVENT_IOC_ENABLE;
const unsigned long flyology_bench_perf_disable_request =
    PERF_EVENT_IOC_DISABLE;
const unsigned long flyology_bench_perf_group_flag = PERF_IOC_FLAG_GROUP;
#else
const long flyology_bench_perf_event_open_call = 0;
const unsigned long flyology_bench_perf_enable_request = 0;
const unsigned long flyology_bench_perf_disable_request = 0;
const unsigned long flyology_bench_perf_group_flag = 0;
#endif

/* Ada reserves its own aligned storage for the recorder registry lock and
 * checks it against this before initializing the mutex in place.
 */
const size_t flyology_bench_pthread_mutex_size = sizeof(pthread_mutex_t);

/* Ada declares the time and resource-usage structures itself, from the
 * field widths the compiler's own platform specification records. These
 * let it check the result against the headers during elaboration rather
 * than trusting the derivation.
 */
const size_t flyology_bench_timeval_bytes = sizeof(struct timeval);
const size_t flyology_bench_timespec_bytes = sizeof(struct timespec);
const size_t flyology_bench_rusage_bytes = sizeof(struct rusage);
const size_t flyology_bench_rusage_counters_offset =
    offsetof(struct rusage, ru_maxrss);

/* ------------------------------------------------------------------ */
/* Fixed command-capture mechanisms.                                   */
/*                                                                     */
/* posix_spawn actions and pollfd are opaque or platform-defined, and  */
/* fcntl is variadic. This boundary therefore owns pipe/spawn setup,    */
/* descriptor flag changes, polling, and wait-status macro decoding.   */
/* Ada imports fixed-signature process calls directly and owns the      */
/* deadline, retry, classification, and capture state machine.          */
/* ------------------------------------------------------------------ */

const int flyology_bench_capture_eintr = EINTR;
const int flyology_bench_capture_eagain = EAGAIN;
const int flyology_bench_capture_ewouldblock = EWOULDBLOCK;
const int flyology_bench_capture_wnohang = WNOHANG;
const int flyology_bench_capture_sigkill = SIGKILL;

static int flyology_bench_capture_lift_descriptor(int *descriptor)
{
    int moved;
    int saved_errno;

    if (*descriptor > STDERR_FILENO) {
        return 0;
    }
    moved = fcntl(*descriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1);
    if (moved < 0) {
        return errno;
    }
    if (close(*descriptor) != 0) {
        saved_errno = errno;
        (void)close(moved);
        return saved_errno;
    }
    *descriptor = moved;
    return 0;
}

int flyology_bench_capture_start(const char *path,
                                 char *const argv[],
                                 int *read_descriptor,
                                 int *child_pid)
{
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    int descriptors[2] = {-1, -1};
    pid_t child = -1;
    int status = 0;
    int spawn_status;
    int saved_errno = 0;
    int actions_initialized = 0;
    int attributes_initialized = 0;
    short spawn_flags = POSIX_SPAWN_SETPGROUP;

    *read_descriptor = -1;
    *child_pid = -1;
#if defined(__linux__)
    if (pipe2(descriptors, O_CLOEXEC) != 0) {
        return errno;
    }
#else
    if (pipe(descriptors) != 0) {
        return errno;
    }
    if (fcntl(descriptors[0], F_SETFD, FD_CLOEXEC) != 0
        || fcntl(descriptors[1], F_SETFD, FD_CLOEXEC) != 0) {
        saved_errno = errno;
        goto failed;
    }
#endif
    status = flyology_bench_capture_lift_descriptor(&descriptors[0]);
    if (status == 0) {
        status = flyology_bench_capture_lift_descriptor(&descriptors[1]);
    }
    if (status != 0) {
        saved_errno = status;
        goto failed;
    }
    status = fcntl(descriptors[0], F_GETFL);
    if (status < 0 || fcntl(descriptors[0], F_SETFL, status | O_NONBLOCK) != 0) {
        saved_errno = errno;
        goto failed;
    }
    status = posix_spawn_file_actions_init(&actions);
    if (status != 0) {
        saved_errno = status;
        goto failed;
    }
    actions_initialized = 1;
    status = posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO);
    if (status == 0) {
        status = posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO);
    }
    if (status == 0) {
        status = posix_spawn_file_actions_addclose(&actions, descriptors[0]);
    }
    if (status == 0) {
        status = posix_spawn_file_actions_addclose(&actions, descriptors[1]);
    }
#if defined(__linux__) && defined(__GLIBC__) && defined(__GLIBC_PREREQ)
#if __GLIBC_PREREQ(2, 34)
    if (status == 0) {
        status = posix_spawn_file_actions_addclosefrom_np(&actions, STDERR_FILENO + 1);
    }
#endif
#endif
    if (status != 0) {
        saved_errno = status;
        goto failed;
    }
    status = posix_spawnattr_init(&attributes);
    if (status != 0) {
        saved_errno = status;
        goto failed;
    }
    attributes_initialized = 1;
    status = posix_spawnattr_setpgroup(&attributes, 0);
    if (status != 0) {
        saved_errno = status;
        goto failed;
    }
#if defined(__APPLE__) && defined(POSIX_SPAWN_CLOEXEC_DEFAULT)
    spawn_flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
    status = posix_spawnattr_setflags(&attributes, spawn_flags);
    if (status != 0) {
        saved_errno = status;
        goto failed;
    }
    spawn_status = posix_spawnp(&child, path, &actions, &attributes, argv, environ);
    (void)posix_spawn_file_actions_destroy(&actions);
    actions_initialized = 0;
    (void)posix_spawnattr_destroy(&attributes);
    attributes_initialized = 0;
    if (spawn_status != 0) {
        saved_errno = spawn_status;
        goto failed;
    }
    (void)close(descriptors[1]);
    descriptors[1] = -1;
    *read_descriptor = descriptors[0];
    *child_pid = (int)child;
    return 0;

failed:
    if (actions_initialized) {
        (void)posix_spawn_file_actions_destroy(&actions);
    }
    if (attributes_initialized) {
        (void)posix_spawnattr_destroy(&attributes);
    }
    if (descriptors[0] >= 0) {
        (void)close(descriptors[0]);
    }
    if (descriptors[1] >= 0) {
        (void)close(descriptors[1]);
    }
    return saved_errno;
}

int flyology_bench_capture_poll(int descriptor, int timeout_ms, int *ready)
{
    struct pollfd item = {descriptor, POLLIN | POLLHUP, 0};

    *ready = poll(&item, 1, timeout_ms);
    return *ready < 0 ? errno : 0;
}

int flyology_bench_capture_exit_status(int wait_status)
{
    if (WIFEXITED(wait_status)) {
        return WEXITSTATUS(wait_status);
    }
    if (WIFSIGNALED(wait_status)) {
        return 128 + WTERMSIG(wait_status);
    }
    return -1;
}

/* Query an already-running power-profiles-daemon through libsystemd. The
 * preliminary name-owner request is passive, so observation does not start a
 * daemon that was absent. Ada owns all string classification and policy. */
#if defined(__linux__)
struct flyology_bench_sd_bus_api {
    void *handle;
    int (*open_system)(void **);
    int (*set_timeout)(void *, uint64_t);
    int (*get_name_creds)(void *, const char *, uint64_t, void **);
    int (*creds_get_unique_name)(void *, const char **);
    void *(*creds_unref)(void *);
    int (*get_property_string)(void *, const char *, const char *, const char *,
                               const char *, void *, char **);
    void *(*bus_unref)(void *);
};

static struct flyology_bench_sd_bus_api flyology_bench_sd_bus;
static pthread_once_t flyology_bench_sd_bus_once = PTHREAD_ONCE_INIT;

static void flyology_bench_initialize_sd_bus(void)
{
    struct flyology_bench_sd_bus_api *api = &flyology_bench_sd_bus;

    api->handle = dlopen("libsystemd.so.0", RTLD_LAZY | RTLD_LOCAL);
    if (api->handle == NULL) {
        return;
    }
    *(void **)(&api->open_system) = dlsym(api->handle, "sd_bus_open_system");
    *(void **)(&api->set_timeout) = dlsym(api->handle, "sd_bus_set_method_call_timeout");
    *(void **)(&api->get_name_creds) = dlsym(api->handle, "sd_bus_get_name_creds");
    *(void **)(&api->creds_get_unique_name) = dlsym(api->handle, "sd_bus_creds_get_unique_name");
    *(void **)(&api->creds_unref) = dlsym(api->handle, "sd_bus_creds_unref");
    *(void **)(&api->get_property_string) = dlsym(api->handle, "sd_bus_get_property_string");
    *(void **)(&api->bus_unref) = dlsym(api->handle, "sd_bus_unref");
    if (api->open_system == NULL || api->set_timeout == NULL || api->get_name_creds == NULL
        || api->creds_get_unique_name == NULL || api->creds_unref == NULL
        || api->get_property_string == NULL || api->bus_unref == NULL) {
        (void)dlclose(api->handle);
        memset(api, 0, sizeof(*api));
    }
}

static int flyology_bench_copy_property(char *target, size_t capacity, const char *source)
{
    size_t length;

    if (target == NULL || capacity == 0 || source == NULL) {
        return -1;
    }
    length = strlen(source);
    if (length >= capacity) {
        return -1;
    }
    memcpy(target, source, length + 1);
    return 0;
}
#endif

int flyology_bench_linux_ppd_open(void **bus)
{
#if defined(__linux__)
    struct flyology_bench_sd_bus_api *api = &flyology_bench_sd_bus;
    int status;

    *bus = NULL;
    status = pthread_once(&flyology_bench_sd_bus_once, flyology_bench_initialize_sd_bus);
    if (status != 0 || api->handle == NULL) {
        return -ENOSYS;
    }
    return api->open_system(bus);
#else
    (void)bus;
    return -ENOSYS;
#endif
}

int flyology_bench_linux_ppd_set_timeout(void *bus, uint64_t timeout_us)
{
#if defined(__linux__)
    return flyology_bench_sd_bus.set_timeout(bus, timeout_us);
#else
    (void)bus;
    (void)timeout_us;
    return -ENOSYS;
#endif
}

int flyology_bench_linux_ppd_get_name_credentials(void *bus, const char *destination,
                                                   void **credentials)
{
#if defined(__linux__)
    *credentials = NULL;
    return flyology_bench_sd_bus.get_name_creds(bus, destination, UINT64_C(1) << 31,
                                                credentials);
#else
    (void)bus;
    (void)destination;
    (void)credentials;
    return -ENOSYS;
#endif
}

int flyology_bench_linux_ppd_copy_unique_name(void *credentials, char *target,
                                               size_t capacity)
{
#if defined(__linux__)
    const char *unique_name = NULL;
    int status = flyology_bench_sd_bus.creds_get_unique_name(credentials, &unique_name);

    if (status < 0) {
        return status;
    }
    return flyology_bench_copy_property(target, capacity, unique_name);
#else
    (void)credentials;
    (void)target;
    (void)capacity;
    return -ENOSYS;
#endif
}

int flyology_bench_linux_ppd_get_property(void *bus, const char *destination,
                                          const char *path, const char *interface,
                                          const char *property, char *target,
                                          size_t capacity)
{
#if defined(__linux__)
    char *value = NULL;
    int status = flyology_bench_sd_bus.get_property_string(
        bus, destination, path, interface, property, NULL, &value);

    if (status >= 0 && flyology_bench_copy_property(target, capacity, value) != 0) {
        status = -ENOSPC;
    }
    free(value);
    return status;
#else
    (void)bus;
    (void)destination;
    (void)path;
    (void)interface;
    (void)property;
    (void)target;
    (void)capacity;
    return -ENOSYS;
#endif
}

void flyology_bench_linux_ppd_credentials_unref(void *credentials)
{
#if defined(__linux__)
    (void)flyology_bench_sd_bus.creds_unref(credentials);
#else
    (void)credentials;
#endif
}

void flyology_bench_linux_ppd_bus_unref(void *bus)
{
#if defined(__linux__)
    (void)flyology_bench_sd_bus.bus_unref(bus);
#else
    (void)bus;
#endif
}

/* Foundation exposes current thermal pressure and effective low-power mode */
/* through NSProcessInfo. Loading the Objective-C runtime dynamically keeps */
/* those optional Darwin APIs out of every downstream link command.          */
#if defined(__APPLE__)
struct flyology_bench_darwin_condition_api {
    void *foundation;
    void *objective_c;
    void *metal;
    void *process;
    void *responds_selector;
    void *thermal_selector;
    void *power_selector;
    void *profile_selector;
    long *default_profile_value;
    long *sustained_profile_value;
    signed char (*send_responds)(void *, void *, void *);
    long (*send_long)(void *, void *);
    signed char (*send_bool)(void *, void *);
    signed char (*send_profile)(void *, void *, long);
};

static struct flyology_bench_darwin_condition_api flyology_bench_darwin_conditions;
static pthread_once_t flyology_bench_darwin_conditions_once = PTHREAD_ONCE_INIT;

static void flyology_bench_initialize_darwin_conditions(void)
{
    typedef void *(*get_class_fn)(const char *);
    typedef void *(*register_name_fn)(const char *);
    typedef void *(*send_object_fn)(void *, void *);
    struct flyology_bench_darwin_condition_api *api = &flyology_bench_darwin_conditions;
    get_class_fn get_class;
    register_name_fn register_name;
    send_object_fn send_object;
    void *process_class;

    api->foundation = dlopen("/System/Library/Frameworks/Foundation.framework/Foundation",
                             RTLD_LAZY | RTLD_LOCAL);
    api->objective_c = dlopen("/usr/lib/libobjc.A.dylib", RTLD_LAZY | RTLD_LOCAL);
    if (api->foundation == NULL || api->objective_c == NULL) {
        return;
    }
    get_class = (get_class_fn)dlsym(api->objective_c, "objc_getClass");
    register_name = (register_name_fn)dlsym(api->objective_c, "sel_registerName");
    send_object = (send_object_fn)dlsym(api->objective_c, "objc_msgSend");
    api->send_long = (long (*)(void *, void *))dlsym(api->objective_c, "objc_msgSend");
    api->send_bool = (signed char (*)(void *, void *))dlsym(api->objective_c, "objc_msgSend");
    api->send_responds =
        (signed char (*)(void *, void *, void *))dlsym(api->objective_c, "objc_msgSend");
    api->send_profile =
        (signed char (*)(void *, void *, long))dlsym(api->objective_c, "objc_msgSend");
    if (get_class == NULL || register_name == NULL || send_object == NULL || api->send_long == NULL) {
        return;
    }
    process_class = get_class("NSProcessInfo");
    api->process = process_class == NULL ? NULL : send_object(process_class, register_name("processInfo"));
    api->responds_selector = register_name("respondsToSelector:");
    api->thermal_selector = register_name("thermalState");
    api->power_selector = register_name("isLowPowerModeEnabled");
    api->profile_selector = register_name("hasPerformanceProfile:");
    api->metal = dlopen("/System/Library/Frameworks/Metal.framework/Metal", RTLD_LAZY | RTLD_LOCAL);
    if (api->metal != NULL) {
        api->default_profile_value = (long *)dlsym(api->metal, "NSProcessPerformanceProfileDefault");
        api->sustained_profile_value =
            (long *)dlsym(api->metal, "NSProcessPerformanceProfileSustained");
    }
}
#endif

int flyology_bench_darwin_process_conditions(int *thermal_available,
                                              int *thermal_state,
                                              int *low_power_available,
                                              int *low_power,
                                              int *profile_available,
                                              int *default_profile,
                                              int *sustained_profile)
{
#if defined(__APPLE__)
    struct flyology_bench_darwin_condition_api *api = &flyology_bench_darwin_conditions;
    int status;

    *thermal_available = 0;
    *thermal_state = 0;
    *low_power_available = 0;
    *low_power = 0;
    *profile_available = 0;
    *default_profile = 0;
    *sustained_profile = 0;
    status = pthread_once(&flyology_bench_darwin_conditions_once,
                          flyology_bench_initialize_darwin_conditions);
    if (status != 0 || api->process == NULL || api->responds_selector == NULL
        || api->thermal_selector == NULL || api->power_selector == NULL
        || api->profile_selector == NULL) {
        errno = ENOSYS;
        return -1;
    }
    if (api->send_responds(api->process, api->responds_selector, api->thermal_selector)) {
        *thermal_available = 1;
        *thermal_state = (int)api->send_long(api->process, api->thermal_selector);
    }
    if (api->send_responds(api->process, api->responds_selector, api->power_selector)) {
        *low_power_available = 1;
        *low_power = api->send_bool(api->process, api->power_selector) ? 1 : 0;
    }
    if (api->metal != NULL && api->default_profile_value != NULL
        && api->sustained_profile_value != NULL
        && api->send_responds(api->process, api->responds_selector, api->profile_selector)) {
        *profile_available = 1;
        *default_profile =
            api->send_profile(api->process, api->profile_selector, *api->default_profile_value) ? 1 : 0;
        *sustained_profile =
            api->send_profile(api->process, api->profile_selector, *api->sustained_profile_value) ? 1 : 0;
    }
    return 0;
#else
    (void)thermal_available;
    (void)thermal_state;
    (void)low_power_available;
    (void)low_power;
    (void)profile_available;
    (void)default_profile;
    (void)sustained_profile;
    errno = ENOSYS;
    return -1;
#endif
}

/* ------------------------------------------------------------------ */
/* Monotonic clock.                                                    */
/* ------------------------------------------------------------------ */

uint64_t flyology_bench_mach_ticks(void)
{
#if defined(__APPLE__)
    return mach_absolute_time();
#else
    return 0;
#endif
}

int flyology_bench_mach_timebase(uint32_t *numerator, uint32_t *denominator)
{
#if defined(__APPLE__)
    mach_timebase_info_data_t timebase;

    if (mach_timebase_info(&timebase) != KERN_SUCCESS) {
        errno = EIO;
        return -1;
    }
    *numerator = timebase.numer;
    *denominator = timebase.denom;
    return 0;
#else
    (void)numerator;
    (void)denominator;
    errno = ENOSYS;
    return -1;
#endif
}

/* ------------------------------------------------------------------ */
/* Thread identity and placement.                                      */
/* ------------------------------------------------------------------ */

uint64_t flyology_bench_native_thread_id(void)
{
#if defined(__APPLE__)
    uint64_t identifier = 0;

    if (pthread_threadid_np(NULL, &identifier) != 0) {
        return 0;
    }
    return identifier;
#else
    return (uint64_t)syscall(__NR_gettid);
#endif
}

/* Binds the calling thread to one logical CPU. The caller has already
 * rejected CPU numbers above flyology_bench_cpu_limit.
 */
int flyology_bench_bind_thread(unsigned int cpu)
{
#if defined(__APPLE__)
    thread_affinity_policy_data_t policy = {(integer_t) (cpu + 1)};
    thread_port_t thread = mach_thread_self();
    kern_return_t status = thread_policy_set(
        thread, THREAD_AFFINITY_POLICY,
        (thread_policy_t)&policy, THREAD_AFFINITY_POLICY_COUNT);

    (void)mach_port_deallocate(mach_task_self(), thread);
    if (status != KERN_SUCCESS) {
        errno = EINVAL;
        return -1;
    }
    return 0;
#else
    cpu_set_t set;
    int status;

    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    status = pthread_setaffinity_np(pthread_self(), sizeof(set), &set);
    if (status != 0) {
        errno = status;
        return -1;
    }
    return 0;
#endif
}

/* ------------------------------------------------------------------ */
/* Telemetry only the Mach interfaces publish.                          */
/*                                                                     */
/* Linux answers the same three questions from /proc, which Ada reads   */
/* directly, so these carry a stub there.                               */
/* ------------------------------------------------------------------ */

int flyology_bench_mach_resident_bytes(uint64_t *bytes)
{
#if defined(__APPLE__)
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;

    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                  (task_info_t)&info, &count) != KERN_SUCCESS) {
        errno = EIO;
        return -1;
    }
    *bytes = (uint64_t)info.resident_size;
    return 0;
#else
    (void)bytes;
    errno = ENOSYS;
    return -1;
#endif
}

int flyology_bench_mach_disk_io(uint64_t *read_bytes, uint64_t *written_bytes)
{
#if defined(__APPLE__)
    struct rusage_info_v2 info;

    if (proc_pid_rusage(getpid(), RUSAGE_INFO_V2,
                        (rusage_info_t *)&info) != 0) {
        return -1;
    }
    *read_bytes = info.ri_diskio_bytesread;
    *written_bytes = info.ri_diskio_byteswritten;
    return 0;
#else
    (void)read_bytes;
    (void)written_bytes;
    errno = ENOSYS;
    return -1;
#endif
}

/* Per-CPU busy and total tick totals. host_processor_info hands back an
 * allocation that only vm_deallocate can release, so the whole exchange
 * stays on this side of the boundary.
 */
int flyology_bench_mach_cpu_ticks(uint64_t *busy_ticks,
                                  uint64_t *total_ticks,
                                  size_t capacity,
                                  size_t *cpu_count)
{
#if defined(__APPLE__)
    host_t host = mach_host_self();
    natural_t count = 0;
    processor_info_array_t raw_info = NULL;
    mach_msg_type_number_t raw_count = 0;
    kern_return_t status = host_processor_info(
        host, PROCESSOR_CPU_LOAD_INFO, &count, &raw_info, &raw_count);
    processor_cpu_load_info_t load_info;

    if (status != KERN_SUCCESS) {
        (void)mach_port_deallocate(mach_task_self(), host);
        errno = EIO;
        return -1;
    }
    if ((size_t)count > capacity) {
        (void)vm_deallocate(mach_task_self(), (vm_address_t)raw_info,
                            (vm_size_t)raw_count * sizeof(integer_t));
        (void)mach_port_deallocate(mach_task_self(), host);
        errno = ENOSPC;
        return -1;
    }
    load_info = (processor_cpu_load_info_t)raw_info;
    for (natural_t cpu = 0; cpu < count; ++cpu) {
        uint64_t user = load_info[cpu].cpu_ticks[CPU_STATE_USER];
        uint64_t system = load_info[cpu].cpu_ticks[CPU_STATE_SYSTEM];
        uint64_t nice = load_info[cpu].cpu_ticks[CPU_STATE_NICE];
        uint64_t idle = load_info[cpu].cpu_ticks[CPU_STATE_IDLE];

        busy_ticks[cpu] = user + system + nice;
        total_ticks[cpu] = busy_ticks[cpu] + idle;
    }
    *cpu_count = (size_t)count;
    (void)vm_deallocate(mach_task_self(), (vm_address_t)raw_info,
                        (vm_size_t)raw_count * sizeof(integer_t));
    (void)mach_port_deallocate(mach_task_self(), host);
    return 0;
#else
    (void)busy_ticks;
    (void)total_ticks;
    (void)capacity;
    (void)cpu_count;
    errno = ENOSYS;
    return -1;
#endif
}

/* ------------------------------------------------------------------ */
/* Per-thread token with an exit callback.                             */
/*                                                                     */
/* pthread_key_create is the only POSIX way to run work when a thread   */
/* ends, and pthread_key_t is an integer whose width differs by         */
/* platform, so the key stays here. The token is opaque: what it owns   */
/* and what releasing it means are decided in Ada.                      */
/* ------------------------------------------------------------------ */

/* The callback lives in the token rather than in a shared variable, so it
 * is written once by the thread that owns it and read only by that thread's
 * destructor.
 */
struct flyology_bench_thread_entry {
    void (*at_exit)(void *);
};

static pthread_key_t flyology_bench_thread_key;
static pthread_once_t flyology_bench_thread_key_once = PTHREAD_ONCE_INIT;
static int flyology_bench_thread_key_status = -1;

static void flyology_bench_thread_key_destroy(void *token)
{
    struct flyology_bench_thread_entry *entry = token;

    if (entry->at_exit != NULL) {
        entry->at_exit(token);
    }
    free(entry);
}

static void flyology_bench_thread_key_initialize(void)
{
    flyology_bench_thread_key_status = pthread_key_create(
        &flyology_bench_thread_key, flyology_bench_thread_key_destroy);
}

/* Returns this thread's token, creating it on first use and arranging for
 * at_exit to run with it when the thread ends. Later calls on the same
 * thread return the same token. Returns NULL with errno set on failure.
 */
void *flyology_bench_thread_token(void (*at_exit)(void *))
{
    struct flyology_bench_thread_entry *entry;
    int status = pthread_once(&flyology_bench_thread_key_once,
                              flyology_bench_thread_key_initialize);

    if (status != 0 || flyology_bench_thread_key_status != 0) {
        errno = status != 0 ? status : flyology_bench_thread_key_status;
        return NULL;
    }
    entry = pthread_getspecific(flyology_bench_thread_key);
    if (entry == NULL) {
        entry = calloc(1, sizeof(*entry));
        if (entry == NULL) {
            return NULL;
        }
        entry->at_exit = at_exit;
        status = pthread_setspecific(flyology_bench_thread_key, entry);
        if (status != 0) {
            free(entry);
            errno = status;
            return NULL;
        }
    }
    return entry;
}
