---
name: flyology-crate-spinout
description: Decide whether Flyology functionality warrants an independent crate or repository, or plan and carry out an approved separation with repository conventions, APM resources, provenance, and consumer migration intact. Use when crate or repository placement is genuinely in question, or when conceiving, extracting, or scaffolding an Ada crate or repository. Do not use for ordinary internal package creation or refactoring that explicitly retains the existing crate and repository boundary; assessment alone does not authorize creating remotes, moving history, publishing, or migrating consumers.
license: Apache-2.0
metadata:
  version: "0.1.0"
---

# Conceive or spin out a crate

Choose the operating mode from the request:

- For a boundary or placement decision, read
  [references/repository-decision.md](references/repository-decision.md).
- For an approved extraction, repository creation, or scaffold, read
  [references/spinout-execution.md](references/spinout-execution.md).
- Read both when the user asks to decide and then execute. Finish the decision
  review and obtain any missing authority before beginning externally mutating
  steps.

Treat these as distinct outcomes, not a binary keep-or-repository choice:

1. keep the functionality as a package in its current crate;
2. make it an independently buildable crate in the current repository; or
3. give the crate an independent repository and lifecycle.

Prefer the smallest boundary that provides the requested independence. A new
repository adds release coordination, version skew, cross-repository changes,
duplicated maintenance, and consumer migration. Directory size, aesthetic
tidiness, or speculative reuse alone do not justify those costs.

## Preserve decision authority

Separate analysis from mutation. A request to assess or recommend a spinout
does not authorize:

- creating or transferring a remote repository;
- rewriting, filtering, or discarding Git history;
- moving or deleting the source of record;
- publishing a crate, release, or tag;
- changing downstream dependency sources or revisions;
- selecting a license, public crate name, version, support promise, or
  compatibility policy that the user has not approved.

Ask for the unresolved choices immediately before they become consequential.
Do not turn a prototype scaffold into an implicit product or compatibility
decision.

## Establish the intended repository shape

Before scaffolding or extracting, identify the intended repository or the
closest maintained sibling that the user wants the result to follow. Inspect
its actual source layout, Alire and GPR files, tests, proofs, formatting,
documentation, CI, release conventions, agent resources, and licensing. Do
not infer a universal Flyology template from one repository.

Record a compact parity table covering:

- the chosen reference repository and revision;
- conventions the new crate will retain;
- conventions that do not apply, with the reason;
- deliberate deviations that require user approval.

Use current maintained scripts and configuration as authority. Copy only the
structure that has a corresponding purpose in the new crate.

## Require agent-resource provisioning

Every new repository must adopt the current Flyology APM composition unless
the user explicitly chooses otherwise:

- shared, cross-repository rules and skills come from
  `flyology-ada/agents` through an updatable dependency such as `ref: main`;
- repository-specific rules and skills remain in local packages under
  `agent-packages/` and are referenced with APM `path` dependencies;
- commit the exact resolution in `apm.lock.yaml`;
- declare both `codex` and `claude` targets and use APM's native deployment
  layouts instead of repository-wide skill symlinks;
- generate and commit `AGENTS.md`; do not hand-edit generated output;
- document APM installation, update, frozen installation, compilation, and
  audit commands in both `README.md` and the maintained agent instructions;
- make CI install the lockfile-frozen graph, validate packages, compile the
  Codex target, audit deployment, and reject generated-output drift.

Install the frozen package graph before compiling generated instructions.
Forward-test fresh Codex and Claude sessions for instruction adherence,
explicit and implicit skill discovery, and an unrelated negative control.

## Complete with review and evidence

Run the shared review cycle on the architecture decision and each extraction
or migration change. Resolve P0 and P1 findings and fix P2 findings by default;
surface any deliberately deferred P2 with its rationale.

Report the selected boundary, authority still required, provenance and
compatibility implications, structure-parity decisions, dependency direction,
verification evidence, and the separately reviewable consumer migration plan.
