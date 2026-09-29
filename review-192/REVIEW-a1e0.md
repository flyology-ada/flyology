# Flyology #192 exact-candidate review refresh

Reviewed head: `a1e0d495221743e2694d49efa0e2a93f9fe3d862`.
Sole parent: `a2693c9d772656227aaa8e85d0e0642d06157af6`.
Prior independently reviewed head: `122d1147b9abfbf56e9478b346a5ccb3a38cc0eb`.
Local evidence checkpoint: 2026-09-15 20:19:32 UTC.

**P0/P1/P2: 0/0/0.** No actionable findings or deferrals.
This completes the bounded local source/focused-test review. Completed exact-head
full gates and a verified published PR remain prerequisites for a public review.

## Exact range and binding reconciliation

Re-read the complete ten-file parent..head diff. Compared the same ten paths
against 122d114: only three fault specifications and the C registry bound differ.
Scheduler body/spec, public topology wrapper, regression source, GPR registration,
and maintained behavioral runner integration are byte-identical to the prior
review. Thus the topology creation/commit checks, same-source/destination check,
registry -> topology -> group locking and early-return unlocks, protected-action
priority, automatic placement ownership, native/dedicated behavior, and private
-3 translation conclusions in REVIEW.md still apply to identical source.

The parent advances the old base only through Thread_Pin finalization behavior,
documentation, and its existing regression (four paths). That inherited change
is outside this #192 patch; refreshed execution-groups coverage uses the actual
new parent implementation. AGENTS.md is byte-identical to the fully read guide.
Author worktree d880 was read-only checked twice and remained clean at the exact
reviewed head. Own checkout remains detached at the original base; new candidate
source was obtained through git archive in candidate-a1e0, with no metadata writes.

Inspected published #142 source at 397797: IDs 46..51 are Poller_Lookup,
Poller_Record_Allocation, Poller_Record_Release, Poller_Control_Add,
Poller_Control_Modify, and Poller_Control_Delete. #192 assigns
Cross_To_Shard_Window = 52 in enabled/disabled runtime Fault_Point and testing
Point specs, with comments reserving 46..51. The existing C test-fault array bound
is 52. A representation-clause-only check confirms unique values, identical paired
runtime bindings, matching testing bindings, and no #192 use of the reserved IDs.
Testing also retains its existing Connect_Interrupted = 35 binding.

No new production constant, public default, resource policy, or C behavior is
introduced. The bound stays within FLYOLOGY_TEST_FAULTS. Compiling platform.c
without that macro passed -std=c11 -Wall -Wextra -Werror; its object has no
flyology_faults registry storage. Existing disabled C test stubs remain present,
as they were before this patch. The direct int -> int Ada import/export and
literal-disabled fault call are unchanged.

## Refreshed independent exact-candidate evidence

Maintained prepare-rts.sh ran from the complete a1e0 archive, with installed GNAT
16.1.0, native default, prepared pool size 1, FLYOLOGY_TEST_FAULTS=1, and all scratch
paths under this own worktree. Exit 0; log prepare-a1e0.log. Reused already-generated
configuration for the matching host/development profile, without selecting a new
dependency or changing source policy.

Fresh focused GPR build: exit 0, log focused-a1e0-build.log. Independently ran each
program under the maintained 30-second bound:

- pool_reduction_cross_to_shard_smoke, launch pool 1: exit 0.
- topology_smoke, launch pool 3: exit 0.
- execution_groups_smoke, launch pool 1: exit 0.

These tests freshly link the configured migration entrypoint and exercise the
rebased runtime/testing fault binding 52. Test stdout/stderr logs use the program
name with suffix -a1e0.log.

Repeated bounded fail-before using the exact parent topology wrapper with the
candidate's deterministic migration pause retained. Hash checks confirm that
wrapper equals a2693c9's wrapper. This is an instrumented equivalent failure path,
not a pristine uninstrumented parent RTS. Build exited 0; regression exited 1:

```
stale shard crossing survived reduction: rejected=FALSE group= 2 explicit= 1
```

Restored the exact a1e0 wrapper, rebuilt, and ran the same regression: exit 0.
Hash checks confirm restored source matches the reviewed commit. Logs:
base-wrapper-a1e0-build.log, fail-before-a1e0.log, restored-a1e0-build.log,
pass-after-a1e0.log.

Refreshed exact-candidate scheduler compilation against the updated disabled
fault specification at both -O0 and -O2: exit 0. Neither object has undefined
test-fault or disabled-hook sentinel references. Logs elision-a1e0-O0.log and
elision-a1e0-O2.log; objects in matching elision-a1e0 directories. These focused
runtime-object checks do not replace full check-test-hook-elision.sh.

git diff --check parent..head: PASS. No full author suite was duplicated. No
stress, performance, TLA, TLAPS, or conformance process was started; no shared
assurance lock was taken. Previous six-test evidence remains historical 122d114
evidence, not silently relabeled as an a1e0 run.

## Full-gate provenance and publication boundary

The author's read-only local build/issue-192-pr.md names exactly a2693c9/a1e0 and
at the checkpoint still marks test.sh, stress.sh, and check-test-hook-elision.sh
pending post-reconciliation/final-head completion. No completed exact-a1e0 full
gate logs were supplied in the handoff. Earlier full-suite results cannot certify
this revised fault ABI. Formatter and diff checks reported in that draft are
author claims; independent diff-check and focused evidence are distinguished above.

One gh query outside sandbox found no PR for codex/issue-192-cross-to-shard-lock.
Await immutable PR URL, verify its published head is exactly a1e0 (or review any
later head), and obtain completed applicable gate provenance before posting an
explicit exact-head public review. No merge, push, code fix, author/main mutation,
other-worktree cleanup, or denied cross-task report retry was performed.
