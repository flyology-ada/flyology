#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
lock_file="$project_root/build/.flyology-alire-rts.lock"
preparation="$project_root/scripts/prepare-alire-rts-internal.sh"

#  Separately located Alire consumers may share one path-pinned dependency.
#  Keep one stable advisory-lock inode: the kernel releases the lock if its
#  owner exits or is killed, while retaining the file avoids unlink races.
mkdir -p "$project_root/build"
case "$(uname -s)" in
  Darwin)
    if [ ! -x /usr/bin/lockf ]; then
      printf '%s\n' "macOS lockf is required for RTS preparation" >&2
      exit 1
    fi
    exec /usr/bin/lockf -k -w "$lock_file" "$preparation"
    ;;
  Linux)
    lock_program=$(command -v flock || true)
    if [ -z "$lock_program" ]; then
      printf '%s\n' "Linux flock is required for RTS preparation" >&2
      exit 1
    fi
    exec "$lock_program" -x "$lock_file" "$preparation"
    ;;
  *)
    printf '%s\n' "unsupported RTS preparation host: $(uname -s)" >&2
    exit 1
    ;;
esac
