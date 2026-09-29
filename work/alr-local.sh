#!/bin/sh
set -eu

task_root=/Users/yrashk/.codex/worktrees/11c2/flyology/work
TMPDIR="$task_root/scratch"
export TMPDIR
exec /usr/local/bin/alr --settings="$task_root/alire-settings" "$@"
