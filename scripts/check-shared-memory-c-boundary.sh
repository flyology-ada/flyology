#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  printf '%s\n' "usage: check-shared-memory-c-boundary.sh ARCHIVE" >&2
  exit 2
fi

archive=$1
symbols=$(nm -g "$archive" | awk '
  /_?flyology_shm_/ && $(NF - 1) != "U" {
    name=$NF
    sub(/^_/, "", name)
    print name
  }
' | sort -u)

for symbol in $symbols; do
  case "$symbol" in
    flyology_shm_fstat_fields|\
    flyology_shm_lstat_fields|\
    flyology_shm_fcntl_getfd|\
    flyology_shm_fcntl_setfd|\
    flyology_shm_fcntl_getfl|\
    flyology_shm_fcntl_get_seals|\
    flyology_shm_fcntl_add_seals|\
    flyology_shm_memfd_create|\
    flyology_shm_getsockname_family|\
    flyology_shm_getpeername_family|\
    flyology_shm_send_fd_once|\
    flyology_shm_receive_fds_once)
      ;;
    *)
      printf '%s\n' "unexpected shared-memory C symbol: $symbol" >&2
      exit 1
      ;;
  esac
done

for required in \
  flyology_shm_fstat_fields \
  flyology_shm_lstat_fields \
  flyology_shm_fcntl_getfd \
  flyology_shm_fcntl_setfd \
  flyology_shm_fcntl_getfl \
  flyology_shm_fcntl_get_seals \
  flyology_shm_fcntl_add_seals \
  flyology_shm_memfd_create \
  flyology_shm_getsockname_family \
  flyology_shm_getpeername_family \
  flyology_shm_send_fd_once \
  flyology_shm_receive_fds_once
do
  if ! printf '%s\n' "$symbols" | grep -Fx "$required" >/dev/null; then
    printf '%s\n' "missing shared-memory C symbol: $required" >&2
    exit 1
  fi
done
