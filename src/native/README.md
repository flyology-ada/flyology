# Native shared-memory admission boundary

Ada owns the shared-memory backing, mapping, registry, descriptor-handoff, and
failure policy. `flyology_shared_memory.c` is limited to host C ABI facts that
cannot be represented as an ordinary fixed-signature Ada import without either
copying an unstable layout or guessing at a macro expansion.

| Retained C leaf | Why a direct Ada import is unsuitable | Ada owner |
| --- | --- | --- |
| `flyology_shm_fstat_fields`, `flyology_shm_lstat_fields` | `struct stat` field locations differ across supported kernels and C libraries. The leaf copies four scalar facts after one call. | Type, size, permission, and namespace-identity validation |
| `flyology_shm_fcntl_*` | `fcntl` is variadic and its command selects the third argument's presence and type. Each leaf performs exactly one command. | CLOEXEC setup, seal policy, error handling, and fallback |
| `flyology_shm_memfd_create` | Older headers omit the wrapper and flags, while the Linux syscall number is supplied by the target headers. The leaf performs one syscall. | Runtime capability fallback, exact sizing, mandatory seals, and security reporting |
| `flyology_shm_getsockname_family`, `flyology_shm_getpeername_family` | The output uses the platform `sockaddr_storage`, `socklen_t`, and `sa_family_t` layouts. Each leaf makes one query and exports only the family. | Endpoint trust and protocol validation |
| `flyology_shm_send_fd_once`, `flyology_shm_receive_fds_once` | `cmsghdr`, alignment, `CMSG_*`, and ancillary traversal are C layout and macro contracts. Each leaf performs one transport call; receive exports all observed descriptors and framing facts. | EINTR retry, exact-one framing, truncation rejection, closing every rejected descriptor, CLOEXEC, poisoning, and backing validation |

Fixed-signature calls such as `close`, `ftruncate`, `mmap`, `munmap`, `msync`,
`fsync`, `getsockopt`, and `setsockopt` are imported directly in the platform
Ada bodies. Stable per-platform flag values live in those bodies. Darwin
`shm_open` and `open` use GNAT's explicit variadic import convention; Linux
`shm_open` uses its fixed-signature convention.

The pure classifiers in `Flyology.Shared_Memory_Policy` are SPARK code. They
decide exact-size and type validity, required security properties, namespace
initialization state, and the exact-one handoff frame. The authoritative proof
script includes that package.

`tests/native/shared_memory_test.c` is not linked into the production library.
It retains only foreign test fixtures that require opaque `posix_spawn` action
objects, wait-status macros, `cmsghdr` construction for adversarial messages,
platform VM reservation APIs, or platform-created adversarial descriptors.
The Ada smoke test owns retry limits, timeouts, assertions, cleanup decisions,
and lifecycle sequencing.

`scripts/check-shared-memory-c-boundary.sh` allowlists every production
`flyology_shm_*` export. `tests/probes/shared_memory_abi_probe.c` compares the
layout-dependent leaves with the host C API. The behavioral shared-memory smoke
test then exercises the Ada policy, including malformed ancillary cleanup and
subprocess handoff.

Admission review conclusion: the production C file contains layout extraction,
macro expansion, variadic/syscall leaves, and one-shot ancillary transport
only. It contains no retries, timeouts, semantic validation, error
classification, resource-lifecycle decision, or multi-syscall cleanup policy.
