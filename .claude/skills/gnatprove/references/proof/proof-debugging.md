# Investigating Unproved Checks

## Concepts

### Six root causes

Every unproved check falls into one of these categories:

| # | Cause | Fix |
|---|-------|-----|
| 1 | Bug in implementation | Fix the code |
| 2 | Assertion too strong | Weaken or correct it |
| 3 | Missing annotation | Add precondition, postcondition, or loop invariant |
| 4 | GNATprove modeling limitation | Use a lemma or introduce an axiom **only with user permission** |
| 5 | Insufficient proof time | Raise `--level` or `--steps` |
| 6 | Prover can't handle the logic | Custom lemma or restructure code |

Causes 1-3 account for the vast majority of proof failures above `--level=2`.

**Before adding a `Loop_Invariant`**: if the failing check is in or after a
small, bounded `for` loop (< 20 iterations, scalar locals only), first confirm
the loop is not already unrolling successfully. A `Loop_Invariant` disables
unrolling and can strictly weaken downstream proof power. See
[loops.md § Read This First](loops.md).

Cause 4 can often been detected by using `--info` and analyzing messages that
SPARK provides indicating imprecise modeling.

Causes 5-6 are rarely permanent at `--level=2` -- exhaust all other
possibilities before concluding the prover is the problem.

The most common mistake is declaring "the SMT solver can't prove this" too
early. In practice, nearly every failure is: wrong code, missing information,
overwhelming context, or a non-inductive invariant. "The prover is too weak"
is the rarest cause.

### Check messages on a conjoined postcondition

A postcondition organized as a conjunction —

```ada
Post => P and then Q and then R
```

— does not give you independent status for each conjunct. When GNATprove
reports a check message on `Q`, that does **not** imply that `P` and `R`
proved. Analysis stops at the first failing conjunct; later conjuncts
may also be unproved and you will only see them once the current failure
is resolved. The same applies with `and`, `or`, and `or else`.

Treat a check on a single conjunct as "at least this one fails" — not as
"only this one fails". Expect fixing it to reveal new failures on
adjacent conjuncts, and plan accordingly when judging progress or
scoping a session.

### Restate a property per branch after a conditional

When a property must hold after an `if`/`case` and fails as a single check on
the merged control-flow path, restate it with a `pragma Assert` at the end of
*each* branch. The prover then discharges it branch-by-branch, with each
branch's concrete state, instead of once against the disjunction of all paths —
which often times out or forces the solver to re-derive the branch split itself.

This is the control-flow analogue of splitting a conjoined postcondition: there
you isolate a conjunct, here you isolate a path. It pairs naturally with the
postcondition case: assert the property in each branch, and the final
postcondition becomes a trivial merge.

Watch the cost: each branch assert is a hypothesis on that path (see the caution
on speculative asserts in
[ghost-code-and-lemmas.md](../spark/ghost-code-and-lemmas.md)). Restate the
property you actually need, not extra scaffolding.

### `--limit-line` as a diagnostic tool

`--limit-line=file.adb:NN` proves **exactly** line NN, assuming all assertions
above it (even unproved ones). This is powerful for what-if exploration:

1. Insert `pragma Assert (P)` above the failing check
2. Run `--limit-line` on the check
3. If it proves, P is sufficient -- go prove P separately
4. If not, P isn't enough -- try a different property

This avoids re-proving the whole subprogram during exploration. You **must**
separately prove any assertions you insert.

#### Conjunct lines in a Post, Contract_Cases, and Exceptional_Cases

When a conjoined `Post`, `Contract_Cases`, and `Exceptional_Cases` is split
across source lines:

```ada
1. Post =>
2.   -- Comment
3.   P
4.   and then Q
5.   and then R
```

GNATprove may report a check message on line 4 (attributed to `Q`), but
**`--limit-line=file.ads:4` is a trap and must not be used here.** GNATprove
will do some analysis and usually report success; that success does
**not** mean `Q` was proved. The check anchored at `Q`'s line is not
targetable in isolation this way.

The only correct `--limit-line` target for this Post (without editing the
source) is the line of the **first term** of the conjunction — line 3
above. Note carefully:

- Line 1 (`Post =>` alone) is wrong — it carries no term.
- Line 2 (a comment) is wrong — likewise.
- Line 4 (`and then Q`) is wrong — it is a continuation, and targeting it
  yields a misleading pass.
- Line 3 (`P`, the first term) is the only correct target; a run at this
  line exercises the whole Post.

If you need to isolate a single conjunct, edit the source to lift it into
a named ghost predicate, expression function, or `pragma Assert` on its
own line — then `--limit-line` can target that line unambiguously.

- For a failing **precondition**, don't use `--limit-line` inside the Pre
  at all; the check fires at the caller, so target the subprogram call
  line at the call site.
- For a failing **loop invariant**, the correct `--limit-line` target is
  the line of the `Loop_Invariant` keyword itself — not the first term of
  the invariant expression.

### GNATprove's "possible fix" suggestions

These are hand-coded heuristics aimed at novice users. Treat them as
directional hints, not commands. They're often right about *what's missing*
but may not suggest the best form of the fix.

## Case-Specific Playbooks

Some check failures have a specific, recurring root cause whose fix is not
obvious from the generic decision tree below — the symptom even points the
wrong way (e.g. a "discriminant check" that has nothing to do with which
variant was accessed). When a symptom here matches, read the linked playbook
*before* working through the decision tree.

| Symptom | Playbook |
|---------|----------|
| `discriminant check` on a whole-object assignment that *changes* a discriminant of a mutable discriminated record | [mutable-discriminants.md](mutable-discriminants.md) |
| `dynamic accessibility check` on a traversal function returning an anonymous `access` derived from a parameter (a `Reference`/`Constant_Reference`-style borrow) | [dynamic-accessibility.md](dynamic-accessibility.md) |
| `type is unsuitable as a source for unchecked conversion` / "might have unused bits" (often with `data representation info unavailable`) | [unchecked-conversion-unused-bits.md](unchecked-conversion-unused-bits.md) |

## Decision Tree

### Step 1: Is the code — and the spec — correct?

Compile with `-gnata` and run tests. If the check fires at runtime,
it's a code bug.

Similarly, if the failing `Post`, ghost predicate, or loop invariant is
new or newly modified, sanity-check the spec itself with 2–3 concrete
values before investing more proof effort: a "not actually true" spec
looks identical to a "hard to prove" one — both manifest as timeouts
or uninterpretable counterexamples. See
[workflow.md § Step 2b](workflow.md#step-2b-sanity-check-specifications).

### Step 2: Missing annotations?

Look for GNATprove hints like "subprogram should mention Var in a precondition."
Add the suggested contract (adjusting form as needed).

### Step 3: Assert breadcrumbs

Binary search for where the proof breaks. Place assertions between where a
property should hold and where GNATprove loses it. If the midpoint proves,
the problem is later.

**Once the missing fact is identified**: if it is an arithmetic ordering or
monotonicity property (e.g. `A * B ≤ C`, `X / Y ≤ X`, monotonicity of a
computed value), jump to Step 6 (Lemmas) — the SPARK Lemma Library may have
it, and a lemma call often makes raising the level unnecessary.

### Step 3a: Need a bound on an input?

If the fix requires bounding a parameter's value, add a precondition on the
current subprogram *or* introduce a subtype — do NOT add a runtime guard
`(if X > Bound then return)`.
Guards are defensive code, which is a SPARK antipattern (see
[contracts.md](../spark/contracts.md)). Push the constraint to the caller via Pre. If
this creates a cascade of preconditions, consider whether the bound belongs in
a subtype instead.

### Step 4: Frame condition?

If a property was established but a call with `in out` makes GNATprove forget
it, the callee needs a frame postcondition. See [contracts.md](../spark/contracts.md).

### Step 5: Increase level

Raise `--level` (0 -> 1 -> 2). Beyond 2 requires user permission. Use
`--steps=N` for reproducibility.

### Step 6: Lemmas

**Before writing a custom lemma, check whether `SPARK.Lemmas.*` has what you need.**

First, verify the SPARK.Lemmas is available in the project:

1. Read the top-level GPR file (the one passed to gnatprove with `-P`).
2. Collect all `with "..."` imports (recursively).
3. For each imported GPR file, check whether it contains `extends "sparklib_internal"`.

If no imported GPR extends `sparklib_internal`: **stop and ask the user to add the sparklib dependency before continuing.** Do not write a custom lemma as a workaround for a missing library import.

If available: find the relevant package in [ghost-code-and-lemmas.md](../spark/ghost-code-and-lemmas.md) and call the lemma at the proof point. If `SPARK.Lemmas.*` has nothing applicable, write a custom lemma.


### Step 7: Last resort (requires user permission)

`pragma Assume` or `pragma Annotate (GNATprove, False_Positive, ...)`.
Document the justification.

## Workflow: Status File Updates

When investigating a failing check:
- **Added Assert breadcrumb** → add "Prove Assert at file:NN" to Discovered Obligations
- **Added/modified a precondition** → add "Re-verify callers of Subprogram" to Discovered Obligations
- **Added frame postcondition** → add "Re-verify callers of Callee" to Discovered Obligations
- **Wrote a ghost lemma** → add "Prove Lemma_Name body" to Discovered Obligations
- **Check now proves** → mark it done in the status file
- **Increased proof level** → note the level in the status entry

## Message Reference

### Severity levels

GNATprove messages fall into four categories:

- **Errors**: SPARK violations, legality issues. Must fix.
- **Warnings**: Suspicious situations (unused variables, potentially
  missing precondition hints, etc.). Treat as errors during a proof
  campaign — consider `--warnings=error` so they stop the run rather
  than getting lost in the noise. A flow warning on a call that bottoms
  out in foreign code is a special case: it often signals an unsound
  external-state model, not noise — see [ffi.md](../spark/ffi.md).
- **Check messages**: Unproved checks, tagged with a **confidence**
  level (`low` / `medium` / `high`) — see next section. All must be
  addressed.
- **Info**: Proved checks (visible with `--report=all`).

### Check-message confidence

The `low` / `medium` / `high` tag on a check message reflects how sure
the tool is that the check is a real problem. This is **not a priority
ranking**; all three mean "this check did not prove".

| Level | Meaning |
|-------|---------|
| `low` | Weak evidence of a real problem. Often a missing precondition, missing hint, or solver-budget issue. |
| `medium` (default) | The prover is confident the check is a real problem but has not validated a concrete failing input. Investigate as you would any proof failure. |
| `high` | GNATprove has **validated a concrete counterexample** — this is a definitively failing input, not "likely" wrong. Treat it as a failing test vector. |

**Do NOT apply `pragma Annotate (GNATprove, False_Positive, ...)` to a
`high` check.** The counterexample proves the condition is reachable;
silencing it hides a real bug. Fix the code or contract.

### Common check categories

| Check | Meaning |
|-------|---------|
| `overflow check` | Arithmetic exceeds type bounds |
| `range check` | Value outside subtype constraint |
| `index check` | Array index out of bounds |
| `division check` | Division by zero |
| `precondition` | Caller doesn't establish callee's Pre |
| `postcondition` | Body doesn't establish Post |
| `loop invariant init` | Invariant false on first iteration |
| `loop invariant preservation` | Invariant not maintained across iteration |
| `discriminant check` | Discriminant constraint violated — *not necessarily* a wrong-variant access; on a whole-object assignment that changes a discriminant, see [Case-Specific Playbooks](#case-specific-playbooks) |
| `dynamic accessibility check` | Accessibility level of an anonymous-access result cannot be bounded statically; common in traversal functions — see [Case-Specific Playbooks](#case-specific-playbooks) |
| `unsuitable as a source for unchecked conversion` | Source type of an `Unchecked_Conversion` may have unused bits (not gap-less); needs a confirming `Object_Size` and/or aliased components with known bounds — see [Case-Specific Playbooks](#case-specific-playbooks) |

### Counterexample interpretation

For `low` and `medium` check messages, counterexamples may not represent
feasible paths. "Impossible" values usually indicate a missing
precondition, not a real bug. Use `--counterexamples=on` (default at
level >= 2).

For `high` check messages, GNATprove has **validated the counterexample**
through its internal checking — it IS a real failing input, not a
spurious path from an overly abstracted model. Plug the CE values into
the failing expression by hand: they will reproduce the failure.
Investigate the code or contract, not the counterexample.

### "all paths raise exceptions"

A `high: all paths in Subprogram_Name raise exceptions or do not
terminate normally` is a **high-confidence check message**, not a
warning. Its usual root cause is a statement that flow analysis can
see is false — typically a `pragma Assert`, `pragma Assume`, or
precondition whose condition is false, often silenced with
`pragma Annotate (GNATprove, False_Positive, ...)`. Since False
implies anything, every path through the subprogram then appears to
raise an exception from the tool's point of view.

The annotation does not hide the contradiction from flow analysis;
it only defers the proof obligation. Flow analysis still models the
suppressed assertion as a potential `Assertion_Error` raise point,
and the derivable False propagates.

**To fix:** find the False_Positive-annotated assertion (or
`pragma Assume`) in the subprogram and verify its condition is actually
true. If it is — strengthen the precondition or body so the prover
can discharge it without the annotation. If it is not — the condition
is false, so the code or contract is wrong and must be changed.
`False_Positive` is not a fix; it is a deferred proof obligation.

## References

- [How to Investigate Unproved Checks](https://docs.adacore.com/live/wave/spark2014/html/spark2014_ug/en/source/how_to_investigate_unproved_checks.html) -- Incorrect code, unprovable properties, prover shortcomings
- [Understanding Counterexamples](https://docs.adacore.com/live/wave/spark2014/html/spark2014_ug/en/gnatprove.html#understanding-counterexamples) -- Interpreting counterexample output
- [Categories of Messages](https://docs.adacore.com/live/wave/spark2014/html/spark2014_ug/en/gnatprove.html#categories-of-messages) -- Info, warning, check, and error message types
