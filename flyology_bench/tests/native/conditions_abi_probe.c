/* Copyright (c) 2026 Yurii Rashkovskii
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */

#include <errno.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <sys/types.h>

extern const int flyology_bench_capture_eintr;
extern const int flyology_bench_capture_eagain;
extern const int flyology_bench_capture_ewouldblock;
int flyology_bench_capture_start(const char *path, char *const argv[],
                                 int *read_descriptor, int *child_pid);
int flyology_bench_capture_read(int descriptor, void *output, size_t capacity,
                                ssize_t *count);
int flyology_bench_capture_poll(int descriptor, int timeout_ms, int *ready);
int flyology_bench_capture_wait(int child_pid, int nohang, int *wait_status,
                                int *result_pid);
int flyology_bench_capture_close(int descriptor);
int flyology_bench_capture_exit_status(int wait_status);
int flyology_bench_darwin_process_conditions(int *thermal_available,
                                              int *thermal_state,
                                              int *low_power_available,
                                              int *low_power,
                                              int *profile_available,
                                              int *default_profile,
                                              int *sustained_profile);
int flyology_bench_linux_ppd_open(void **bus);
int flyology_bench_linux_ppd_set_timeout(void *bus, uint64_t timeout_us);
int flyology_bench_linux_ppd_get_name_credentials(void *bus,
                                                   const char *destination,
                                                   void **credentials);
int flyology_bench_linux_ppd_copy_unique_name(void *credentials, char *target,
                                               size_t capacity);
int flyology_bench_linux_ppd_get_property(void *bus, const char *destination,
                                          const char *path, const char *interface,
                                          const char *property, char *target,
                                          size_t capacity);
void flyology_bench_linux_ppd_credentials_unref(void *credentials);
void flyology_bench_linux_ppd_bus_unref(void *bus);

int main(void)
{
    char output[16];
    char *exact[] = {"/usr/bin/printf", "0123456789abcdef", NULL};
    size_t used = 0;
    int descriptor = -1;
    int child_pid = -1;
    int wait_status = 0;
    int result_pid = 0;
    int child_exited = 0;
    int pipe_eof = 0;
    int attempts = 0;
    int thermal_available = 0;
    int thermal_state = 0;
    int low_power_available = 0;
    int low_power = 0;
    int profile_available = 0;
    int default_profile = 0;
    int sustained_profile = 0;
    void *bus = NULL;
#if defined(__linux__)
    void *credentials = NULL;
    char owner[64];
    char property[64];
#endif
    int status;

    if (flyology_bench_capture_start(exact[0], exact, &descriptor, &child_pid) != 0) {
        return 1;
    }
    while ((!pipe_eof || !child_exited) && attempts++ < 100) {
        ssize_t count = 0;
        int ready = 0;
        char discard;

        if (!pipe_eof) {
            status = flyology_bench_capture_read(
                descriptor, used < sizeof(output) ? output + used : &discard,
                used < sizeof(output) ? sizeof(output) - used : 1, &count);
            if (status == 0 && count == 0) {
                pipe_eof = 1;
            } else if (status == 0 && count > 0) {
                if (used < sizeof(output)) {
                    used += (size_t)count;
                } else {
                    return 4;
                }
            } else if (status != flyology_bench_capture_eintr
                       && status != flyology_bench_capture_eagain
                       && status != flyology_bench_capture_ewouldblock) {
                return 4;
            }
        }
        if (!child_exited) {
            status = flyology_bench_capture_wait(child_pid, 1, &wait_status,
                                                  &result_pid);
            if (status == 0 && result_pid == child_pid) {
                child_exited = 1;
            } else if (status != 0 && status != flyology_bench_capture_eintr) {
                return 5;
            }
        }
        if (!pipe_eof && flyology_bench_capture_poll(descriptor, 10, &ready) != 0) {
            return 8;
        }
    }
    if (pipe_eof && !child_exited) {
        do {
            status = flyology_bench_capture_wait(child_pid, 0, &wait_status,
                                                  &result_pid);
        } while (status == flyology_bench_capture_eintr);
        child_exited = status == 0 && result_pid == child_pid;
    }
    if (flyology_bench_capture_close(descriptor) != 0) {
        return 9;
    }
    if (!pipe_eof) {
        return 10;
    }
    if (!child_exited) {
        return 11;
    }
    if (flyology_bench_capture_exit_status(wait_status) != 0) {
        return 12;
    }
    if (used != sizeof(output)) {
        return 13;
    }
    if (memcmp(output, "0123456789abcdef", sizeof(output)) != 0) {
        return 14;
    }
    status = flyology_bench_darwin_process_conditions(
        &thermal_available, &thermal_state, &low_power_available, &low_power,
        &profile_available, &default_profile, &sustained_profile);
#if defined(__APPLE__)
    if (status != 0 || thermal_available != 1 || thermal_state < 0
        || thermal_state > 3 || low_power_available != 1 || low_power < 0
        || low_power > 1 || profile_available < 0 || profile_available > 1
        || (profile_available == 1
            && default_profile + sustained_profile != 1)) {
        return 2;
    }
#else
    if (status == 0) {
        return 3;
    }
#endif
    status = flyology_bench_linux_ppd_open(&bus);
#if defined(__linux__)
    if (status >= 0) {
        if (flyology_bench_linux_ppd_set_timeout(bus, UINT64_C(250000)) < 0) {
            return 6;
        }
        status = flyology_bench_linux_ppd_get_name_credentials(
            bus, "org.freedesktop.UPower.PowerProfiles", &credentials);
        if (status >= 0) {
            if (flyology_bench_linux_ppd_copy_unique_name(
                    credentials, owner, sizeof(owner)) < 0) {
                return 10;
            }
            flyology_bench_linux_ppd_credentials_unref(credentials);
            (void)flyology_bench_linux_ppd_get_property(
                bus, owner, "/org/freedesktop/UPower/PowerProfiles",
                "org.freedesktop.UPower.PowerProfiles", "ActiveProfile",
                property, sizeof(property));
        }
        flyology_bench_linux_ppd_bus_unref(bus);
    }
#else
    if (status >= 0) {
        return 7;
    }
#endif
    return 0;
}
