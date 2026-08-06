#!/bin/sh
set -eu

if [ -n "${ALR:-}" ]; then
  if [ ! -x "$ALR" ]; then
    printf '%s\n' "ALR is not executable: $ALR" >&2
    exit 1
  fi
  printf '%s\n' "$ALR"
elif command -v alr >/dev/null 2>&1; then
  command -v alr
elif [ -x "$HOME/alr" ]; then
  printf '%s\n' "$HOME/alr"
else
  printf '%s\n' "Alire was not found; set ALR or add alr to PATH" >&2
  exit 1
fi
