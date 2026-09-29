# Proving SPARK Code

This section covers proof campaigns: triage, strategy, debugging unproved checks,
and improving provability.

## Forbidden Without Explicit User Permission

These shortcuts silence or bypass proof failures without resolving them:

| What | Why not |
|------|---------|
| `pragma Assume` | Asserts something true with no verification. Unsound. |
| `pragma Annotate (GNATprove, False_Positive, ...)` | Silences a check without resolving it. |
| Ghost axiom (`with Import`) | Postcondition is assumed true; GNATprove never verifies it. |

In practice, every time these have been suggested, a real fix was found: tighter
preconditions, better type bounds, restructured code, ghost lemmas, loop invariants,
or `pragma Assert` breadcrumbs.

## Hint Strength Ordering

When the prover needs help, reach for the lightest tool first:

1. **`pragma Assert`** — a breadcrumb. If discharged, GNATprove uses it as a
   known fact for subsequent checks.
2. **Ghost lemma** (`is null` or with a body) — a provable ghost procedure.
   GNATprove verifies the postcondition; callers get it for free.
3. **Ghost axiom** (`with Import`) — an assumed-true postcondition GNATprove does
   **not** verify. **Never introduce without explicit user permission.**

See [ghost-code-and-lemmas.md](../spark/ghost-code-and-lemmas.md) for patterns and
examples for each.

## Triage — Choose Your Path

Run GNATprove with `--output=oneline` before reading any code in depth.

**Quick-fix path** — use this if ALL of the following hold:
- All failures are in a single subprogram
- None involve loops, floating-point, or access types
- Each message is self-explanatory (obvious overflow or missing range constraint
  where the fix is immediately clear)

Work inline: read the subprogram, fix each check, re-verifying at `--limit-subp`
(without `-f`) as you go. Once all checks are addressed, run a final
`--limit-subp -f` to confirm — the single `-f` run at the close matches [the
Step 5 widening principle](workflow.md#step-5-widen-scope-and-re-verify). Then
review for antipatterns and widen scope. No proof-status.md or subagents needed.

**Escape hatch**: if any fix appears to be non-obvious, a loop invariant is
needed, or an unexpected check appears, switch to the full campaign path.

**Full campaign** — use this if any failure spans multiple subprograms, involves
loops, floating-point, or access types, or is not immediately self-explanatory.

Read [workflow.md](workflow.md) and follow it from Step 1.

**You MUST invoke a subagent for each subprogram in a full campaign.** Tactical
context (gnatprove output, line-by-line iteration) is noise once a subprogram
proves. Keeping it out of the main context preserves the ability to make strategic
judgments — spotting subtype opportunities, choosing the next leaf, reviewing for
antipatterns.

## Reference Files

| File | When to read |
|------|--------------|
| [workflow.md](workflow.md) | Full campaign structure; proof-status.md format; strategic loop; subagent invocation |
| [workflow-subagent.md](workflow-subagent.md) | Subagent instructions: hard rules, tactical loop, reporting |
| [proof-debugging.md](proof-debugging.md) | Decision tree for unproved checks; six root causes |
| [loops.md](loops.md) | Loop invariants; loop variant (termination) proofs |
| [refactoring-for-proof.md](refactoring-for-proof.md) | When and how to decompose subprograms to improve provability |
| [overflow-patterns.md](overflow-patterns.md) | Integer overflow; intermediate value proofs |
| [floating-point.md](floating-point.md) | FP proof strategies; nonlinear arithmetic |
| [proof-in-ci.md](proof-in-ci.md) | Running gnatprove in CI: caching and provisioning prior to proof |
