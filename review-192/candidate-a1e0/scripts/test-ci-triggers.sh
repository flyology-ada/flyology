#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
workflow=${1:-"$project_root/.github/workflows/ci.yml"}

if ! awk '
  BEGIN {
    in_events = 0
    in_push = 0
    saw_push = 0
    saw_pull_request = 0
    main_only = 0
    all_tags = 0
  }

  $0 == "on:" {
    in_events = 1
    next
  }

  in_events && $0 ~ /^[^[:space:]]/ {
    in_events = 0
    in_push = 0
  }

  in_events && $0 == "  push:" {
    saw_push = 1
    in_push = 1
    next
  }

  in_events && $0 == "  pull_request:" {
    saw_pull_request = 1
    in_push = 0
    next
  }

  in_push && $0 ~ /^    branches-ignore:/ {
    exit 1
  }

  in_events && $0 ~ /^  [[:alnum:]_-]+:/ {
    in_push = 0
  }

  in_push && $0 == "    branches: [main]" {
    main_only = 1
  }

  in_push && $0 == "    tags: [\"**\"]" {
    all_tags = 1
  }

  END {
    exit !(saw_push && saw_pull_request && main_only && all_tags)
  }
' "$workflow"
then
  printf '%s\n' \
    "CI must run for pull requests, main pushes, and tags without also running for feature-branch pushes" >&2
  exit 1
fi
