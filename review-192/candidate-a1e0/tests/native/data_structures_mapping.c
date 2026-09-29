#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#if !defined(MAP_ANONYMOUS)
#define MAP_ANONYMOUS MAP_ANON
#endif

int flyology_test_mapping_create(const char *path, size_t length,
                                  void **first, void **second, int *fd)
{
    int descriptor = open(path, O_CREAT | O_EXCL | O_RDWR, 0600);
    void *left;
    void *right;

    if (descriptor < 0 || ftruncate(descriptor, (off_t)length) != 0) {
        if (descriptor >= 0) {
            close(descriptor);
            unlink(path);
        }
        return -1;
    }
    left = mmap(NULL, length, PROT_READ | PROT_WRITE, MAP_SHARED,
                descriptor, 0);
    right = mmap(NULL, length, PROT_READ | PROT_WRITE, MAP_SHARED,
                 descriptor, 0);
    if (left == MAP_FAILED || right == MAP_FAILED || left == right) {
        if (left != MAP_FAILED) {
            munmap(left, length);
        }
        if (right != MAP_FAILED) {
            munmap(right, length);
        }
        close(descriptor);
        unlink(path);
        return -1;
    }
    *first = left;
    *second = right;
    *fd = descriptor;
    return 0;
}

int flyology_test_mapping_unmap_and_reserve(void *address, size_t length)
{
    void *reserved;

    if (munmap(address, length) != 0) {
        return -1;
    }
    reserved = mmap(address, length, PROT_NONE,
                    MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
    return reserved == address ? 0 : -1;
}

int flyology_test_mapping_remap(int fd, size_t length, void **address)
{
    void *result = mmap(NULL, length, PROT_READ | PROT_WRITE,
                        MAP_SHARED, fd, 0);
    if (result == MAP_FAILED) {
        return -1;
    }
    *address = result;
    return 0;
}

int flyology_test_mapping_unmap(void *address, size_t length)
{
    return address == NULL ? 0 : munmap(address, length);
}

int flyology_test_mapping_close(const char *path, int fd)
{
    int close_result = fd < 0 ? 0 : close(fd);
    int unlink_result = unlink(path);
    return close_result == 0 && unlink_result == 0 ? 0 : -1;
}

uint32_t flyology_test_mapping_read_u32(const void *base, size_t offset)
{
    uint32_t result;
    memcpy(&result, (const unsigned char *)base + offset, sizeof(result));
    return result;
}

uint64_t flyology_test_mapping_read_u64(const void *base, size_t offset)
{
    uint64_t result;
    memcpy(&result, (const unsigned char *)base + offset, sizeof(result));
    return result;
}

void flyology_test_mapping_write_u32(void *base, size_t offset,
                                     uint32_t value)
{
    memcpy((unsigned char *)base + offset, &value, sizeof(value));
}

void flyology_test_mapping_write_u64(void *base, size_t offset,
                                     uint64_t value)
{
    memcpy((unsigned char *)base + offset, &value, sizeof(value));
}

int flyology_test_mapping_contains_u64(const void *base, size_t length,
                                       uint64_t value)
{
    const unsigned char *bytes = base;
    size_t offset;

    for (offset = 0; offset + sizeof(value) <= length; ++offset) {
        uint64_t candidate;
        memcpy(&candidate, bytes + offset, sizeof(candidate));
        if (candidate == value) {
            return 1;
        }
    }
    return 0;
}
