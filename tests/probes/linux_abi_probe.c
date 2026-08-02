#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <unistd.h>

long gnatevl_linux_io_setup(unsigned entries, unsigned long *context);
long gnatevl_linux_io_destroy(unsigned long context);
long gnatevl_linux_io_submit(unsigned long context, long count, void *controls);
long gnatevl_linux_io_cancel(unsigned long context, void *control, void *result);
long gnatevl_linux_io_getevents(unsigned long context, long minimum, long count,
                                void *events, void *timeout);
long gnatevl_linux_io_uring_setup(unsigned entries, void *parameters);
long gnatevl_linux_io_uring_enter(int descriptor, unsigned to_submit,
                                  unsigned minimum, unsigned flags,
                                  void *signal_mask, size_t signal_size);
long gnatevl_linux_io_uring_register(int descriptor, unsigned opcode,
                                     void *argument, unsigned count);

struct gnatevl_epoll_event {
    uint32_t events;
    int descriptor;
};

int gnatevl_linux_epoll_ctl(int epoll_fd, int operation, int descriptor,
                            uint32_t events);
int gnatevl_linux_epoll_wait(int epoll_fd,
                             struct gnatevl_epoll_event *events,
                             int max_events, int timeout_ms);

static int failed_as_syscall(long result) {
    return result == -1 && errno != 0;
}

static int check_epoll_translation(void) {
    struct gnatevl_epoll_event events[3] = {
        { 0, -1 }, { 0, -1 }, { UINT32_C(0xdeadbeef), -123 }
    };
    uint64_t one = 1;
    int epoll_fd = -1;
    int first = -1;
    int second = -1;
    int count;
    int saw_first = 0;
    int saw_second = 0;
    int index;
    int failed = 0;

    epoll_fd = epoll_create1(EPOLL_CLOEXEC);
    first = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    second = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    if (epoll_fd < 0 || first < 0 || second < 0) {
        perror("epoll translation setup");
        failed = 1;
        goto cleanup;
    }
    if (gnatevl_linux_epoll_ctl(epoll_fd, EPOLL_CTL_ADD, first,
                                EPOLLIN | EPOLLONESHOT) != 0 ||
        gnatevl_linux_epoll_ctl(epoll_fd, EPOLL_CTL_ADD, second,
                                EPOLLIN | EPOLLONESHOT) != 0 ||
        write(first, &one, sizeof(one)) != (ssize_t)sizeof(one) ||
        write(second, &one, sizeof(one)) != (ssize_t)sizeof(one)) {
        perror("epoll translation registration");
        failed = 1;
        goto cleanup;
    }

    count = gnatevl_linux_epoll_wait(epoll_fd, events, 2, 1000);
    if (count != 2) {
        fprintf(stderr, "epoll bridge returned %d events, expected 2\n", count);
        failed = 1;
        goto cleanup;
    }
    for (index = 0; index < count; ++index) {
        if ((events[index].events & EPOLLIN) == 0) {
            fprintf(stderr, "epoll bridge lost EPOLLIN mask\n");
            failed = 1;
        }
        saw_first |= events[index].descriptor == first;
        saw_second |= events[index].descriptor == second;
    }
    if (!saw_first || !saw_second) {
        fprintf(stderr, "epoll bridge lost or corrupted a descriptor\n");
        failed = 1;
    }
    if (events[2].events != UINT32_C(0xdeadbeef) ||
        events[2].descriptor != -123) {
        fprintf(stderr, "epoll bridge overwrote the adjacent output record\n");
        failed = 1;
    }

cleanup:
    if (second >= 0) {
        close(second);
    }
    if (first >= 0) {
        close(first);
    }
    if (epoll_fd >= 0) {
        close(epoll_fd);
    }
    return failed;
}

int main(void) {
    int failures = 0;

#define EXPECT_FAILURE(call)                                                    \
    do {                                                                        \
        errno = 0;                                                              \
        if (!failed_as_syscall((call))) {                                       \
            fprintf(stderr, "wrapper did not preserve -1/errno: %s\n", #call); \
            ++failures;                                                         \
        }                                                                       \
    } while (0)

    EXPECT_FAILURE(gnatevl_linux_io_setup(1, NULL));
    EXPECT_FAILURE(gnatevl_linux_io_destroy(~0UL));
    EXPECT_FAILURE(gnatevl_linux_io_submit(~0UL, 1, NULL));
    EXPECT_FAILURE(gnatevl_linux_io_cancel(~0UL, NULL, NULL));
    EXPECT_FAILURE(gnatevl_linux_io_getevents(~0UL, 0, 1, NULL, NULL));
    EXPECT_FAILURE(gnatevl_linux_io_uring_setup(0, NULL));
    EXPECT_FAILURE(gnatevl_linux_io_uring_enter(-1, 0, 0, 0, NULL, 0));
    EXPECT_FAILURE(gnatevl_linux_io_uring_register(-1, 0, NULL, 0));

    failures += check_epoll_translation();
    if (failures != 0) {
        return 1;
    }
    puts("linux syscall and epoll ABI bridges: PASS");
    return 0;
}
