---
name: ada-concurrency-ownership-review
description: Review Ada concurrency and ownership across tasks, protected objects, callbacks, cancellation, abort, finalization, buffers, and foreign resources. Use for races, blocking behavior, lifetime safety, ownership transfer, or cooperative scheduling concerns.
license: Apache-2.0
metadata:
  version: "0.1.0"
---

# Review concurrency and ownership

Trace each resource from creation through publication, transfer, cancellation,
completion, and finalization. Include exceptional and aborted paths.

## Concurrency model

- Identify the task or protected object that owns each mutable state machine.
- Distinguish native blocking, cooperative suspension, kernel completion,
  callbacks, and polling.
- Check lock order, protected-operation restrictions, blocking calls, reentry,
  wakeup protocols, lost-wake gaps, and priority-sensitive behavior.
- Establish whether a value is copied, borrowed, moved, shared, or retained by
  foreign or kernel code.
- Check that borrowed storage outlives every pending operation and that a moved
  value has one owner at every point.
- Verify cancellation and abort drain external references before storage is
  reclaimed.
- Verify finalization is non-leaking, idempotent where required, and safe after
  partial initialization.
- Confirm that no two schedulers, callbacks, or tasks can resume or complete
  the same operation concurrently.

## Evidence

Use implementation paths, tasking contracts, protected-state transitions, and
tests. Do not infer safety solely from intended call order. When a bound or
queue capacity is part of the design, establish its authority rather than
inventing one.

## Output

Provide an ownership timeline for each risky resource and findings with the
interleaving or lifecycle path that triggers them. Distinguish proven
invariants from assumptions that require user or implementation decisions.
