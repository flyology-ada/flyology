#define _GNU_SOURCE

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

struct gnatevl_file_completion {
    uintptr_t token;
    int64_t result;
    int error;
    int reserved;
};

#if defined(__APPLE__)

#include <aio.h>
#include <signal.h>

struct gnatevl_file_engine {
    int kqueue_fd;
};

struct gnatevl_aio_request {
    struct aiocb control;
};

void *gnatevl_file_engine_create(int poller_fd, int wake_fd) {
    struct gnatevl_file_engine *engine;

    (void)wake_fd;
    engine = calloc(1, sizeof(*engine));
    if (engine != NULL) {
        engine->kqueue_fd = poller_fd;
    }
    return engine;
}

void gnatevl_file_engine_destroy(void *opaque) {
    free(opaque);
}

int gnatevl_file_engine_submit(
    void *opaque,
    int fd,
    void *buffer,
    size_t length,
    int64_t offset,
    int for_write,
    uintptr_t token,
    int *error_code)
{
    struct gnatevl_file_engine *engine = opaque;
    struct gnatevl_aio_request *request;
    int result;

    request = calloc(1, sizeof(*request));
    if (request == NULL) {
        *error_code = ENOMEM;
        return -1;
    }

    request->control.aio_fildes = fd;
    request->control.aio_offset = offset;
    request->control.aio_buf = buffer;
    request->control.aio_nbytes = length;
    request->control.aio_reqprio = 0;
    request->control.aio_sigevent.sigev_notify = SIGEV_KEVENT;
    request->control.aio_sigevent.sigev_signo = engine->kqueue_fd;
    request->control.aio_sigevent.sigev_value.sival_ptr = (void *)token;

    result = for_write != 0
        ? aio_write(&request->control)
        : aio_read(&request->control);
    if (result != 0) {
        *error_code = errno;
        free(request);
        return -1;
    }

    *error_code = 0;
    return 0;
}

int gnatevl_file_engine_complete(
    void *opaque,
    uintptr_t request_address,
    int64_t result,
    int error_code,
    struct gnatevl_file_completion *completion)
{
    struct gnatevl_aio_request *request =
        (struct gnatevl_aio_request *)request_address;

    (void)opaque;
    completion->token =
        (uintptr_t)request->control.aio_sigevent.sigev_value.sival_ptr;
    completion->result = result >= 0 ? result : 0;
    completion->error = error_code;
    completion->reserved = 0;
    free(request);
    return 0;
}

int gnatevl_file_engine_drain(
    void *opaque,
    struct gnatevl_file_completion *completions,
    unsigned capacity)
{
    (void)opaque;
    (void)completions;
    (void)capacity;
    return 0;
}

#elif defined(__linux__)

#include <linux/io_uring.h>
#include <linux/aio_abi.h>
#include <stdatomic.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>

#define GNATEVL_RING_ENTRIES 1024U

enum gnatevl_linux_file_backend {
    GNATEVL_BACKEND_IO_URING,
    GNATEVL_BACKEND_LINUX_AIO
};

static void gnatevl_ring_failure(const char *operation) {
    fprintf(stderr, "GNATEVL: %s failed: %s\n", operation, strerror(errno));
}

struct gnatevl_file_engine {
    enum gnatevl_linux_file_backend backend;
    aio_context_t aio_context;
    int wake_fd;
    int ring_fd;
    void *sq_mapping;
    void *cq_mapping;
    void *sqes_mapping;
    size_t sq_mapping_size;
    size_t cq_mapping_size;
    size_t sqes_mapping_size;
    _Atomic unsigned *sq_head;
    _Atomic unsigned *sq_tail;
    unsigned *sq_mask;
    unsigned *sq_entries;
    unsigned *sq_array;
    struct io_uring_sqe *sqes;
    _Atomic unsigned *cq_head;
    _Atomic unsigned *cq_tail;
    unsigned *cq_mask;
    struct io_uring_cqe *cqes;
};

static void gnatevl_unmap_engine(struct gnatevl_file_engine *engine) {
    if (engine->backend == GNATEVL_BACKEND_LINUX_AIO) {
        if (engine->aio_context != 0) {
            syscall(__NR_io_destroy, engine->aio_context);
        }
        return;
    }
    if (engine->sqes_mapping != MAP_FAILED && engine->sqes_mapping != NULL) {
        munmap(engine->sqes_mapping, engine->sqes_mapping_size);
    }
    if (engine->cq_mapping != engine->sq_mapping
        && engine->cq_mapping != MAP_FAILED
        && engine->cq_mapping != NULL)
    {
        munmap(engine->cq_mapping, engine->cq_mapping_size);
    }
    if (engine->sq_mapping != MAP_FAILED && engine->sq_mapping != NULL) {
        munmap(engine->sq_mapping, engine->sq_mapping_size);
    }
    if (engine->ring_fd >= 0) {
        close(engine->ring_fd);
    }
}

void *gnatevl_file_engine_create(int poller_fd, int wake_fd) {
    struct gnatevl_file_engine *engine;
    struct io_uring_params parameters;
    size_t shared_size;
    int result;

    (void)poller_fd;
    engine = calloc(1, sizeof(*engine));
    if (engine == NULL) {
        return NULL;
    }
    engine->ring_fd = -1;
    engine->backend = GNATEVL_BACKEND_IO_URING;
    engine->wake_fd = wake_fd;
    engine->sq_mapping = MAP_FAILED;
    engine->cq_mapping = MAP_FAILED;
    engine->sqes_mapping = MAP_FAILED;
    memset(&parameters, 0, sizeof(parameters));

    engine->ring_fd = (int)syscall(
        __NR_io_uring_setup, GNATEVL_RING_ENTRIES, &parameters);
    if (engine->ring_fd < 0) {
        if (errno != ENOSYS && errno != EPERM) {
            gnatevl_ring_failure("io_uring_setup");
            free(engine);
            return NULL;
        }
        engine->backend = GNATEVL_BACKEND_LINUX_AIO;
        engine->aio_context = 0;
        result = (int)syscall(
            __NR_io_setup, GNATEVL_RING_ENTRIES, &engine->aio_context);
        if (result < 0) {
            gnatevl_ring_failure("io_setup fallback");
            free(engine);
            return NULL;
        }
        return engine;
    }

    engine->sq_mapping_size =
        parameters.sq_off.array + parameters.sq_entries * sizeof(unsigned);
    engine->cq_mapping_size =
        parameters.cq_off.cqes
        + parameters.cq_entries * sizeof(struct io_uring_cqe);
    if ((parameters.features & IORING_FEAT_SINGLE_MMAP) != 0) {
        shared_size = engine->sq_mapping_size > engine->cq_mapping_size
            ? engine->sq_mapping_size
            : engine->cq_mapping_size;
        engine->sq_mapping_size = shared_size;
        engine->cq_mapping_size = shared_size;
    }

    engine->sq_mapping = mmap(
        NULL,
        engine->sq_mapping_size,
        PROT_READ | PROT_WRITE,
        MAP_SHARED,
        engine->ring_fd,
        IORING_OFF_SQ_RING);
    if (engine->sq_mapping == MAP_FAILED) {
        gnatevl_ring_failure("io_uring SQ mmap");
        gnatevl_unmap_engine(engine);
        free(engine);
        return NULL;
    }

    if ((parameters.features & IORING_FEAT_SINGLE_MMAP) != 0) {
        engine->cq_mapping = engine->sq_mapping;
    } else {
        engine->cq_mapping = mmap(
            NULL,
            engine->cq_mapping_size,
            PROT_READ | PROT_WRITE,
            MAP_SHARED,
            engine->ring_fd,
            IORING_OFF_CQ_RING);
        if (engine->cq_mapping == MAP_FAILED) {
            gnatevl_ring_failure("io_uring CQ mmap");
            gnatevl_unmap_engine(engine);
            free(engine);
            return NULL;
        }
    }

    engine->sqes_mapping_size =
        parameters.sq_entries * sizeof(struct io_uring_sqe);
    engine->sqes_mapping = mmap(
        NULL,
        engine->sqes_mapping_size,
        PROT_READ | PROT_WRITE,
        MAP_SHARED,
        engine->ring_fd,
        IORING_OFF_SQES);
    if (engine->sqes_mapping == MAP_FAILED) {
        gnatevl_ring_failure("io_uring SQE mmap");
        gnatevl_unmap_engine(engine);
        free(engine);
        return NULL;
    }

    engine->sq_head = (_Atomic unsigned *)
        ((char *)engine->sq_mapping + parameters.sq_off.head);
    engine->sq_tail = (_Atomic unsigned *)
        ((char *)engine->sq_mapping + parameters.sq_off.tail);
    engine->sq_mask = (unsigned *)
        ((char *)engine->sq_mapping + parameters.sq_off.ring_mask);
    engine->sq_entries = (unsigned *)
        ((char *)engine->sq_mapping + parameters.sq_off.ring_entries);
    engine->sq_array = (unsigned *)
        ((char *)engine->sq_mapping + parameters.sq_off.array);
    engine->sqes = (struct io_uring_sqe *)engine->sqes_mapping;
    engine->cq_head = (_Atomic unsigned *)
        ((char *)engine->cq_mapping + parameters.cq_off.head);
    engine->cq_tail = (_Atomic unsigned *)
        ((char *)engine->cq_mapping + parameters.cq_off.tail);
    engine->cq_mask = (unsigned *)
        ((char *)engine->cq_mapping + parameters.cq_off.ring_mask);
    engine->cqes = (struct io_uring_cqe *)
        ((char *)engine->cq_mapping + parameters.cq_off.cqes);

    result = (int)syscall(
        __NR_io_uring_register,
        engine->ring_fd,
        IORING_REGISTER_EVENTFD_ASYNC,
        &wake_fd,
        1U);
    if (result < 0 && errno == EINVAL) {
        result = (int)syscall(
            __NR_io_uring_register,
            engine->ring_fd,
            IORING_REGISTER_EVENTFD,
            &wake_fd,
            1U);
    }
    if (result < 0) {
        gnatevl_ring_failure("io_uring eventfd registration");
        gnatevl_unmap_engine(engine);
        free(engine);
        return NULL;
    }
    return engine;
}

void gnatevl_file_engine_destroy(void *opaque) {
    struct gnatevl_file_engine *engine = opaque;

    if (engine != NULL) {
        gnatevl_unmap_engine(engine);
        free(engine);
    }
}

int gnatevl_file_engine_submit(
    void *opaque,
    int fd,
    void *buffer,
    size_t length,
    int64_t offset,
    int for_write,
    uintptr_t token,
    int *error_code)
{
    struct gnatevl_file_engine *engine = opaque;
    struct io_uring_sqe *entry;
    unsigned head;
    unsigned tail;
    unsigned index;
    int result;

    if (engine->backend == GNATEVL_BACKEND_LINUX_AIO) {
        struct iocb *control = calloc(1, sizeof(*control));
        struct iocb *controls[1];

        if (control == NULL) {
            *error_code = ENOMEM;
            return -1;
        }
        control->aio_data = (uint64_t)token;
        control->aio_lio_opcode =
            for_write != 0 ? IOCB_CMD_PWRITE : IOCB_CMD_PREAD;
        control->aio_fildes = (uint32_t)fd;
        control->aio_buf = (uint64_t)(uintptr_t)buffer;
        control->aio_nbytes = (uint64_t)length;
        control->aio_offset = offset;
        control->aio_flags = IOCB_FLAG_RESFD;
        control->aio_resfd = (uint32_t)engine->wake_fd;
        controls[0] = control;
        do {
            result = (int)syscall(
                __NR_io_submit, engine->aio_context, 1L, controls);
        } while (result < 0 && errno == EINTR);
        if (result != 1) {
            *error_code = result < 0 ? errno : EAGAIN;
            free(control);
            return -1;
        }
        *error_code = 0;
        return 0;
    }

    if (length > UINT32_MAX) {
        *error_code = EINVAL;
        return -1;
    }

    head = atomic_load_explicit(engine->sq_head, memory_order_acquire);
    tail = atomic_load_explicit(engine->sq_tail, memory_order_relaxed);
    if (tail - head >= *engine->sq_entries) {
        *error_code = EAGAIN;
        return -1;
    }

    index = tail & *engine->sq_mask;
    entry = &engine->sqes[index];
    memset(entry, 0, sizeof(*entry));
    entry->opcode = for_write != 0 ? IORING_OP_WRITE : IORING_OP_READ;
    entry->fd = fd;
    entry->off = (uint64_t)offset;
    entry->addr = (uint64_t)(uintptr_t)buffer;
    entry->len = (uint32_t)length;
    entry->user_data = (uint64_t)token;
    engine->sq_array[index] = index;
    atomic_store_explicit(engine->sq_tail, tail + 1U, memory_order_release);

    do {
        result = (int)syscall(
            __NR_io_uring_enter, engine->ring_fd, 1U, 0U, 0U, NULL, 0U);
    } while (result < 0 && errno == EINTR);

    if (result != 1) {
        atomic_store_explicit(engine->sq_tail, tail, memory_order_release);
        *error_code = result < 0 ? errno : EAGAIN;
        return -1;
    }

    *error_code = 0;
    return 0;
}

int gnatevl_file_engine_complete(
    void *opaque,
    uintptr_t request_address,
    int64_t result,
    int error_code,
    struct gnatevl_file_completion *completion)
{
    (void)opaque;
    (void)request_address;
    (void)result;
    (void)error_code;
    (void)completion;
    return -1;
}

int gnatevl_file_engine_drain(
    void *opaque,
    struct gnatevl_file_completion *completions,
    unsigned capacity)
{
    struct gnatevl_file_engine *engine = opaque;
    unsigned head;
    unsigned tail;
    unsigned count = 0;

    if (engine->backend == GNATEVL_BACKEND_LINUX_AIO) {
        struct io_event *events;
        struct timespec timeout = {0, 0};
        int result;

        if (capacity == 0) {
            return 0;
        }
        events = calloc(capacity, sizeof(*events));
        if (events == NULL) {
            return -1;
        }
        do {
            result = (int)syscall(
                __NR_io_getevents,
                engine->aio_context,
                0L,
                (long)capacity,
                events,
                &timeout);
        } while (result < 0 && errno == EINTR);
        if (result < 0) {
            free(events);
            return -1;
        }
        for (int index = 0; index < result; ++index) {
            completions[index].token = (uintptr_t)events[index].data;
            completions[index].result = events[index].res >= 0
                ? events[index].res
                : 0;
            completions[index].error = events[index].res < 0
                ? (int)-events[index].res
                : (events[index].res2 < 0 ? (int)-events[index].res2 : 0);
            completions[index].reserved = 0;
            free((void *)(uintptr_t)events[index].obj);
        }
        free(events);
        return result;
    }

    head = atomic_load_explicit(engine->cq_head, memory_order_relaxed);
    tail = atomic_load_explicit(engine->cq_tail, memory_order_acquire);
    while (head != tail && count < capacity) {
        struct io_uring_cqe *entry = &engine->cqes[head & *engine->cq_mask];

        completions[count].token = (uintptr_t)entry->user_data;
        completions[count].result = entry->res >= 0 ? entry->res : 0;
        completions[count].error = entry->res < 0 ? -entry->res : 0;
        completions[count].reserved = 0;
        ++count;
        ++head;
    }
    atomic_store_explicit(engine->cq_head, head, memory_order_release);
    return (int)count;
}

#else
#error "GNATEVL file engine requires Darwin or Linux"
#endif
