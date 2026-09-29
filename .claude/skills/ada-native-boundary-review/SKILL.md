---
name: ada-native-boundary-review
description: Review Ada interfaces to C, operating-system APIs, assembly, and compiler intrinsics. Use when adding or changing native bridges, imports, representation clauses, callbacks, syscalls, or ABI-sensitive code. Prefer direct Ada imports and keep policy in Ada.
license: Apache-2.0
metadata:
  version: "0.1.0"
---

# Review a native boundary

Start from the rule that Ada is the implementation language. A C bridge needs
a repository-grounded reason that direct Ada import or a typed Ada record with
representation clauses is unsuitable.

## Boundary classification

Identify whether the boundary requires:

- preprocessor-only constants or compile-time layout assertions;
- a variadic function;
- an opaque callback or function-pointer dispatch;
- architecture-specific intrinsics unavailable from Ada;
- assembly-level context or register handling;
- only a fixed-signature function or stable ABI record that Ada can import
  directly.

Retain native code only for the mechanism that truly needs native semantics.

## Policy audit

Move retry logic, validation, error classification, timeout arithmetic,
ownership, cleanup order, state machines, and syscall sequencing into Ada when
Ada can express them. Check that the bridge does not retain Ada-owned storage
beyond its valid lifetime or hide blocking work on a cooperative thread.

Validate sizes, alignment, signedness, calling convention, errno handling,
descriptor ownership, nullability, callback lifetime, and platform selection.
Require focused ABI and symbol tests for a new or materially expanded bridge.

## Output

State why each retained native function cannot be a direct Ada import. List
policy that should move to Ada, ABI assumptions that need executable checks,
and any user decision required. Separate a strict behavioral translation from
semantic repairs so each remains reviewable.
