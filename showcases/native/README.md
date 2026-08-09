# Shared image index native boundary

`shared_image_index_process.c` is linked only into the showcase. Direct Ada
imports are unsuitable for its two retained representations:

- `posix_spawn_file_actions_t` is opaque and must be initialized, populated,
  passed to `posix_spawn`, and destroyed through the host C API;
- successful child termination is exposed through the `WIFEXITED` and
  `WEXITSTATUS` macros rather than callable symbols.

The socketpair leaf creates both endpoints close-on-exec, using the native
socket flag or the variadic `fcntl` ABI as the host permits. The spawn leaf does
only the sequencing inherent in the opaque action object and duplicates the
one intentional child endpoint onto descriptor 3, clearing close-on-exec for
that exec boundary. The wait leaf makes one `waitpid` observation. Ada owns
every socket and child process, SCM_RIGHTS transfer, acceptance acknowledgment,
retry, timeout, termination, and cleanup decision.

`check-shared-image-index-native.sh` fixes the exported symbol set. Building
and running the showcase is the focused ABI test: it execs independent workers,
hands each one a descriptor through the duplicated endpoint, observes their
portable exit status, and fails if any boundary fact is wrong.
