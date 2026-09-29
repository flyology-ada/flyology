# Flyology #192 independent bounded review

Historical review of 122d114. The current review is [REVIEW-a1e0.md](REVIEW-a1e0.md).

Candidate: `122d1147b9abfbf56e9478b346a5ccb3a38cc0eb`.
Sole parent/base: `e9dd856b20f45345ae870d00ebcc9d9dca2f887d`.
Superseded candidate ae828 was not reviewed.

Findings sweep: **P0/P1/P2 0/0/0**; no actionable findings and no deferrals.
Rubric: P0 immediate catastrophic defect; P1 serious correctness/safety defect;
P2 bounded correctness or compatibility defect requiring correction.

Read the normal 1,132-line AGENTS.md and relevant README execution-group/sharding
sections, current issue #192, all ten changed files, base migration code, pool
reduction population/cutover code, transfer, destruction, and finalization locking.
Did not read .claude rules or edit implementation worktrees.

## Independent failure derivation

The base wrapper reads the configured pool before calling unrestricted migration.
Reduction can publish a smaller ceiling before migration commits. Unrestricted
migration then clears Automatic_Placement and transfers into the removed group.
The reduction counts and drains automatic tasks only, so the explicit task escapes
drainage. This is a bounded P2 race requiring concurrent crossing and reduction;
it does not establish task corruption, wrong application results, or deadlock.

The fix checks the pool with the topology lock held before lazy target creation
and again at migration commit. A same-group configured crossing validates under
the same lock before its no-op result. The commit rejection releases topology and
registry-shard locks without acquiring a group lock or changing fiber state.
Migration retains shard -> topology -> group lock order. Existing rejection paths
release their acquired locks, and Ensure_Group retains its exception cleanup.
The unrestricted Migrate wrapper passes False; dedicated reservations, native
rejection, pins, outstanding file operations, and ordinary migration remain on
the existing paths. Protected-action refusal precedes same-group/configured
outcomes. Private -3 translates to existing Migration_Error; -2 to Program_Error.
No public constant/default/capacity is introduced.

The new C-signature boundary is an Ada Import/Export of int -> int, without a C
implementation. The only C diff extends the existing atomic test-fault registry
from 45 to 46 entries. No scheduling, retry, validation, or ownership policy moves
to C. Enabled/disabled runtime fault enums and test control keep identical values.
The pause has no locks held, remains within the literal disabled guard, and keeps
the worker alive until the test explicitly releases it. Exception cleanup disarms
the pause and releases the worker before leaving its Ada master.

## Independent focused evidence

Built a private git archive of the exact candidate using the maintained
prepare-rts.sh with installed GNAT 16.1.0, native default, prepared pool size 1,
and FLYOLOGY_TEST_FAULTS=1. Runtime build exited 0. Copied already-generated GPR
configuration for the matching host/profile; no source policy changes.

Focused GPR build exited 0. Each following program ran under the maintained
30-second timeout and independently returned exit 0:

- pool_reduction_cross_to_shard_smoke (launch pool 1)
- topology_smoke (launch pool 3)
- pool_reduction_smoke (launch pool 3)
- pool_reduction_inert_smoke (launch pool 3)
- protected_action_blocking_smoke (launch pool 1; file artifacts in local scratch)
- execution_groups_smoke (launch pool 1)

For fail-before, copied the exact base topology wrapper into the private archive,
rebuilt the crossing regression, and kept the candidate's deterministic pause on
the unrestricted migration path. That path matches the base migration behavior
with test instrumentation; this is not a pristine uninstrumented base RTS run.
The regression exited 1 with:

```
stale shard crossing survived reduction: rejected=FALSE group= 2 explicit= 1
```

Restored the exact candidate wrapper, rebuilt, and ran the same regression:
exit 0. Logs: fail-before.log, pass-after.log, base-wrapper-build.log,
restored-build.log, focused-build.log, prepare-candidate-local.log.

Compiled the exact candidate scheduler against the disabled runtime fault spec
at -O0 and -O2 with the maintained runtime Ada switches. Both builds exited 0.
Neither object's undefined symbols include test faults or disabled-hook sentinels.
The enabled runtime object exports flyology_runtime_migrate and the new
flyology_runtime_migrate_configured. The matching Ada declaration/import and
successful link/run provide focused ABI evidence. These object checks do not
replace the author's full check-test-hook-elision.sh gate.

git diff --check base..candidate passed. Hash checks confirm restored private
topology and scheduler sources match candidate objects in the shared repository.
No exhaustive behavioral/stress suite was duplicated; no TLA, conformance, or
performance process was started, and no shared assurance lock was taken.

## Pending immutable handoff

One gh PR query found no PR for codex/issue-192-cross-to-shard-lock. The author's
local draft reports test.sh and stress.sh passed and full hook elision pending;
those reports are not independent exact-head gate verification. Await immutable
PR URL/head SHA and completed gate/log handoff before posting an exact-head
GitHub review. No merge, implementation push, code fix, or other-worktree cleanup.

## Boundaries encountered

git switch was denied while attempting shared metadata index.lock creation;
checkout stayed on clean detached base. Did not retry or escalate. A read-only
git archive provided a source copy in the writable own workspace.

Initial RTS tool discovery failed before runtime production because Alire tried
GitHub through a /tmp settings root. Did not reuse that discovery path. Supplying
the installed GNAT prefix used the maintained local-tool path; all deliberate
review artifacts and scratch paths are under this worktree.

Automatic approval review rejected a message requesting author gate handoff and
then rejected a master status message, citing lack of trusted authorization for
internal review payload/destination. Did not retry or use another transport.
Cross-task reporting awaits user approval; local review evidence remains here.
