#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <mach/mach.h>
#include <mach/mach_vm.h>
#endif

extern char **environ;

int flyology_shm_open_named(const char *, unsigned long long, unsigned int,
                            int, int *, int *, int *);
int flyology_shm_open_file(const char *, unsigned long long, unsigned int,
                           int, int *, int *);

int flyology_test_is_linux(void)
{
#if defined(__linux__)
    return 1;
#else
    return 0;
#endif
}

#if !defined(MAP_ANONYMOUS)
#define MAP_ANONYMOUS MAP_ANON
#endif

static int set_cloexec(int fd)
{
    int flags = fcntl(fd, F_GETFD);
    return flags >= 0 && fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0;
}

int flyology_test_shared_socketpair(int *left, int *right)
{
    int pair[2];
#if defined(SOCK_CLOEXEC)
    if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, pair) != 0)
        return -1;
#else
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0)
        return -1;
    if (!set_cloexec(pair[0]) || !set_cloexec(pair[1])) {
        close(pair[0]); close(pair[1]); return -1;
    }
#endif
    *left = pair[0];
    *right = pair[1];
    return 0;
}

int flyology_test_spawn_shared_memory_child(const char *program, int socket_fd,
                                              unsigned long long parent_base,
                                              unsigned long long length,
                                              int *pid_out)
{
    char base_text[32];
    char length_text[32];
    char *arguments[4];
    posix_spawn_file_actions_t actions;
    pid_t child;
    int error;
    snprintf(base_text, sizeof(base_text), "%llu", parent_base);
    snprintf(length_text, sizeof(length_text), "%llu", length);
    arguments[0] = (char *)program;
    arguments[1] = base_text;
    arguments[2] = length_text;
    arguments[3] = NULL;
    if (posix_spawn_file_actions_init(&actions) != 0) return -1;
    if (posix_spawn_file_actions_adddup2(&actions, socket_fd, 3) != 0) {
        posix_spawn_file_actions_destroy(&actions); return -1;
    }
    error = posix_spawn(&child, program, &actions, NULL, arguments, environ);
    posix_spawn_file_actions_destroy(&actions);
    if (error != 0) return -1;
    *pid_out = (int)child;
    return 0;
}

int flyology_test_wait_shared_memory_child(int pid)
{
    int status;
    for (int attempt = 0; attempt < 10000; ++attempt) {
        pid_t result = waitpid((pid_t)pid, &status, WNOHANG);
        if (result == (pid_t)pid) {
            return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : -1;
        }
        if (result < 0 && errno != EINTR) return -1;
        usleep(1000);
    }
    kill((pid_t)pid, SIGKILL);
    (void)waitpid((pid_t)pid, &status, 0);
    return -1;
}

int flyology_test_reserve_mapping_base(unsigned long long base,
                                        unsigned long long length)
{
#if defined(__APPLE__)
    mach_vm_address_t requested = (mach_vm_address_t)base;
    kern_return_t result = mach_vm_allocate(
        mach_task_self(), &requested, (mach_vm_size_t)length, VM_FLAGS_FIXED);
    if (result == KERN_SUCCESS) return 0;
    if (result == KERN_INVALID_ADDRESS ||
        result == KERN_PROTECTION_FAILURE ||
        result == KERN_NO_SPACE)
        return 1;
    return -1;
#else
    void *requested = (void *)(uintptr_t)base;
    void *result;
    int flags = MAP_PRIVATE | MAP_ANONYMOUS;
#if defined(MAP_FIXED_NOREPLACE)
    flags |= MAP_FIXED_NOREPLACE;
#elif defined(MAP_EXCL)
    flags |= MAP_FIXED | MAP_EXCL;
#else
    (void)requested; (void)length; return -2;
#endif
    result = mmap(requested, (size_t)length, PROT_NONE, flags, -1, 0);
    if (result == MAP_FAILED && errno == EEXIST) return 1;
    return result == requested ? 0 : -1;
#endif
}

int flyology_test_release_reserved_base(unsigned long long base,
                                         unsigned long long length)
{
#if defined(__APPLE__)
    return mach_vm_deallocate(mach_task_self(), (mach_vm_address_t)base,
                              (mach_vm_size_t)length) == KERN_SUCCESS ? 0 : -1;
#else
    return munmap((void *)(uintptr_t)base, (size_t)length) == 0 ? 0 : -1;
#endif
}

int flyology_test_close_shared_socket(int fd)
{
    return close(fd) == 0 ? 0 : -1;
}

int flyology_test_send_two_descriptors(int socket_fd, int first, int second)
{
    unsigned char payload = 0x46;
    int descriptors[2] = { first, second };
    struct iovec iov = { &payload, 1 };
    union { struct cmsghdr align; unsigned char bytes[CMSG_SPACE(sizeof(descriptors))]; } control;
    struct msghdr message;
    struct cmsghdr *header;
    memset(&control, 0, sizeof(control));
    memset(&message, 0, sizeof(message));
    message.msg_iov = &iov;
    message.msg_iovlen = 1;
    message.msg_control = control.bytes;
    message.msg_controllen = sizeof(control.bytes);
    header = CMSG_FIRSTHDR(&message);
    header->cmsg_level = SOL_SOCKET;
    header->cmsg_type = SCM_RIGHTS;
    header->cmsg_len = CMSG_LEN(sizeof(descriptors));
    memcpy(CMSG_DATA(header), descriptors, sizeof(descriptors));
    return sendmsg(socket_fd, &message, 0) == 1 ? 0 : -1;
}

int flyology_test_size_changes_rejected(int fd, unsigned long long length)
{
    int grow_rejected = ftruncate(fd, (off_t)(length + 1)) != 0;
    int shrink_rejected = ftruncate(fd, (off_t)(length - 1)) != 0;
    return grow_rejected && shrink_rejected ? 1 : 0;
}

int flyology_test_create_unsized_shm(const char *name, int *fd_out)
{
    int fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
    if (fd < 0 || !set_cloexec(fd)) {
        if (fd >= 0) { close(fd); shm_unlink(name); }
        return -1;
    }
    *fd_out = fd;
    return 0;
}

int flyology_test_close_unsized_shm(const char *name, int fd)
{
    int close_result = close(fd);
    int unlink_result = shm_unlink(name);
    return close_result == 0 && unlink_result == 0 ? 0 : -1;
}

int flyology_test_unlink_shm(const char *name)
{
    return shm_unlink(name) == 0 ? 0 : -1;
}

int flyology_test_failed_named_create_cleanup(const char *name)
{
    int fd = -1;
    int properties = 0;
    int outcome = 0;
    int probe;
    int result = flyology_shm_open_named(
        name, (unsigned long long)LLONG_MAX + 1ULL, 0600, 0,
        &fd, &properties, &outcome);
    if (result == 0) {
        close(fd);
        shm_unlink(name);
        return 0;
    }
    probe = shm_open(name, O_RDWR, 0);
    if (probe >= 0) {
        close(probe);
        shm_unlink(name);
        return 0;
    }
    return errno == ENOENT ? 1 : 0;
}

int flyology_test_failed_file_create_cleanup(const char *path)
{
    int fd = -1;
    int properties = 0;
    int result = flyology_shm_open_file(
        path, (unsigned long long)LLONG_MAX + 1ULL, 0600, 1,
        &fd, &properties);
    if (result == 0) {
        close(fd);
        unlink(path);
        return 0;
    }
    return lstat(path, &(struct stat){0}) != 0 && errno == ENOENT ? 1 : 0;
}

void flyology_test_store_mapping_u64(void *base, unsigned long long offset,
                                     uint64_t value)
{
    __atomic_store_n((uint64_t *)((unsigned char *)base + offset), value,
                     __ATOMIC_RELEASE);
}
