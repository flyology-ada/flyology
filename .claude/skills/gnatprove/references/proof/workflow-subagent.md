# GNATprove Tactical Loop (Subagent)

You are a subagent in a SPARK proof campaign. Your role is to prove all checks
in a single assigned subprogram, then report results to the main agent.

The main agent owns strategic decisions (ordering, reviewing, widening scope).
Your job is the four steps below for your assigned subprogram only.

## Hard Rules — Read Before Anything Else

These are absolute constraints. Violating them corrupts proof state or wastes
compute. No exception exists unless the user has explicitly stated otherwise.

| Rule | Detail |
|------|--------|
| **`-j0` by default** | Every gnatprove invocation must include `-j0` (all cores) unless the user has explicitly specified a different parallelism limit. |
| **`--output-header` on every run** | Every gnatprove invocation must include `--output-header`. It prepends an invocation header (command line, version, host, timestamp) to `gnatprove.out`, which is how the main agent verifies what you actually ran in [workflow.md § Step 3b](workflow.md#step-3b-verify-subagent-results). Your session is opaque to the main agent; this header is how your work becomes auditable. Omitting it forces the main agent to take your report on trust. |
| **One instance at a time** | Never launch two gnatprove processes concurrently. GNATprove assumes exclusive ownership of its output directories; parallel runs collide and corrupt results. |
| **`-f` forbidden** | Never pass `-f`. GNATprove's incremental cache gives you correct results for every tactical run; `-f` forces a full recompile + flow reanalysis and is always wasteful here. `-f` belongs to the main agent's closing widening pass ([workflow.md § Step 5](workflow.md#step-5-widen-scope-and-re-verify)). If you think you need `-f`, stop and hand back to the main agent. |
| **`-u` and broader scope forbidden** | Never use `-u` as your only scope — without `--limit-subp` or `--limit-line`, it proves every subprogram in the unit. Whole-program scope (no `-u` or `--limit-*`) belongs to the main agent's strategic loop. Running with `-u` alone proves every subprogram in the unit and wastes significant compute. |
| **Default to `--limit-subp`; `--limit-line` is the focus lens** | Every gnatprove invocation must be scoped at least to `--limit-subp=file.adb:NN`. This is the right default: one run re-proves every check in the subprogram, so you see *all* progress at once — more token-efficient than re-running per check. Drop to `--limit-line=file.adb:MM` **only** when a single check is stubborn enough to warrant isolating it (e.g., broader output is too noisy to interpret, or you want to test a hypothesis on one check without disturbing others). Return to `--limit-subp` once the sticky point is past. |
| **Never re-run to understand output** | Re-running gnatprove is only permitted after a code or contract change, or to increase proof level. Launching a fresh run solely to re-read output is forbidden. Instead, pipe every run through `tee` (see Step 3) so you can re-filter the captured output with grep/sed without a new run. `gnatprove.out` is also available for deeper investigation. *Exception: `--explain CODE` is a documentation lookup — it does not invoke the prover and is always permitted when output contains an explain code.* |
| **Bash tool timeout** | GNATprove can run for tens of minutes — there is no way to predict duration in advance. Always set a large `timeout` on the Bash tool call: at minimum 300000ms (5 min) for `--limit-subp` runs, and 600000ms (10 min) or more for broader scope. If the run times out but produced output, work with that output — only re-run with a larger timeout if **no output was produced at all**. Note the timeout for future runs. |

## Your Assignment

The main agent's prompt will give you:
- **Subprogram**: name and file/line of declaration
- **Project**: how to invoke gnatprove (bare `gnatprove` or `alr gnatprove`)
- **Target level**: maximum proof level to use (usually 1 or 2)
- **Callee contracts**: known postconditions of callees, or "see proof-status.md"
- **Constraints**: structural requirements (e.g. "use preconditions not guards")

## Stop and Report — When to End the Session

Your session ends cleanly one of two ways: all assigned checks prove, or
one of the trip-wires below fires. The trip-wires exist because subagent
sessions are opaque to the user — every minute you spend grinding past a
stop-condition is a minute the user cannot see, and a minute the main
agent cannot re-steer.

When a trip-wire fires, stop immediately and return a structured report
(see **Final Report** below). Do not try to salvage, retry, or work around
the condition.

| Trip-wire | Trigger | Why you stop |
|-----------|---------|--------------|
| **Distinct-attempt cap** | 3 structurally distinct ideas on the same check have failed | Local iteration is exhausted. The 4th idea belongs to a fresh session or to the main agent's strategic re-planning — not to you. |
| **Wall-clock trip-wire** | ~45 min on a single check without closing it | A proof trap. Decomposing, escalating level, widening scope, or skipping the check are all strategic calls. |
| **Out-of-scope edit** | A candidate fix would touch a file, subprogram, type, or contract outside the scope named in your brief | Your brief names exactly what you may edit. Anything else is a strategic decision, even if the edit looks obvious. |
| **Tool-error cascade** | ≥3 consecutive build/compile failures (gnatprove never reached the prover) | Degenerate state. You are not getting proof feedback, so you are not iterating — you are flailing. |
| **False premise from the brief** | A fact the brief supplied as true ("use lemma `L` — it gives you `X`") turns out to be false — you have a concrete counterexample or an irreducible contradiction | Strategic miss: the main agent's plan depends on something that isn't so. You cannot fix this without rewriting the plan. |

### Guard on the false-premise trip-wire

"I can't prove it at level 2" is *not* the same as "the premise is false."
The prover failing to discharge `X` does not mean `X` is untrue; it may
just be hard. Fire this trip-wire only when you have one of:

- A concrete counterexample — values that satisfy the premise's stated
  `Pre` and falsify its stated claim, verified on paper.
- An irreducible contradiction — the premise plus other accepted facts
  entails `False` by straightforward reasoning.

Otherwise, treat the failure as a normal stubborn check and apply the
distinct-attempt cap or wall-clock trip-wire.

### Final Report

When you stop — whether you proved all checks or a trip-wire fired —
return:

- **Outcome**: all-proved, or trip-wire name + triggering check
- **Proved**: which checks closed, at what level
- **Remaining**: which checks are still open
- **Attempts** (per remaining check): the distinct ideas tried and one
  line on why each failed
- **One named next step**: your best guess at what to try next, framed
  so the main agent can accept, modify, or reject it
- **New obligations**: lemmas, asserts, or frame conditions you added
  that still need discharging (also reflected in `proof-status.md` per
  the table below)

Keep the report terse. The main agent reads it to decide the next
invocation — not to re-live your session.

## Proof Status Updates

`proof-status.md` is located alongside the code. Update it as you work:

| Event | Action |
|-------|--------|
| Start | Confirm subprogram is listed under "In Progress"; add its failing checks if missing |
| Check proves | Tick off that check in "In Progress" |
| Add `pragma Assert` breadcrumb at line KK | Discovered Obligations: "Prove Assert at file:KK" |
| Write ghost lemma `Lemma_Foo` | Discovered Obligations: "Prove Lemma_Foo body" |
| Add or change a precondition | Discovered Obligations: "Re-verify callers of Subprogram_Name" |
| Add frame postcondition | Discovered Obligations: "Re-verify callers of Callee_Name" |
| All checks ticked off | Run `--limit-subp=file.adb:N` (**no `-f`** — forbidden in the tactical loop); report pass/fail, level used, new obligations. The main agent does the `-f` widening pass in [workflow.md § Step 5](workflow.md#step-5-widen-scope-and-re-verify). |

When updating `proof-status.md`:

- **Keep it honest**: if a subprogram is "Proved" but you later change its callee's
  contract, move it back to "Not Started" (it needs re-verification)
- **Don't write line numbers**: as you edit files, line numbers will become
  incorrect. Use names (for subprograms) or descriptions (for messages) so you
  can find the right location again after source files are updated.

---

## Subagent: Tactical Loop

### Step 1: Read the Right Things

For the subprogram under proof, read:
- The **subprogram itself** (body + contracts)
- The **specifications** (not bodies) of its callees
- The **data types** involved

SPARK is modular: callee bodies are irrelevant for proof. Only the callee's
contract matters. If a callee has no contract, only its parameter types matter.
*Exception*: expression functions without a postcondition are inlined for
proof; so are subprograms marked with the aspect
`Annotate => (GNATprove, Inline_For_Proof)`.

### Step 2: Evaluate Decomposition

**Before annotating, evaluate whether this subprogram should be decomposed.**

A subprogram is a decomposition candidate when it contains self-contained intermediate computations whose *results* — not their internals — matter to the calling code. If you can write a short, meaningful postcondition for the extracted piece, extract it: the prover sees less context, the contract is reusable, and the code is better.

A subprogram is NOT a decomposition candidate when its parts are so tightly coupled that extracted subprograms would need postconditions that essentially restate their entire computation. When the contract for an extracted piece would be as complex as the implementation itself, decomposition adds overhead without helping the prover.

**When in doubt, decompose.** Most proof-resistant monolithic code contains separable intermediate computations that were simply never extracted.

See [refactoring-for-proof.md](refactoring-for-proof.md) for patterns.

### Step 3: Iterate on the Subprogram

#### Iteration (default: whole subprogram)

Iterate at `--limit-subp` scope. One run re-proves every check in the
subprogram, which gives you the status of all checks at once — more
token-efficient than running per check, and it catches new failures your
edits introduced that a single-check run would hide. **Always pipe output
through `tee`** so you can re-filter it later without re-running:

```bash
gnatprove ... -j0 --output-header --limit-subp=file.adb:NN 2>&1 | tee gnatprove-run.txt
```

**Line numbers are not stable across edits.** Do not assume the previous `NN`
remains valid after inserting, deleting, or moving code/comments/contracts
above the target. After any such change, you *must* re-locate the subprogram
declaration's current line number before the next run.

To re-examine the output (e.g. filter to a different pattern), read or grep
`gnatprove-run.txt` — do not re-run gnatprove.

#### When to narrow to `--limit-line`

Drop to `--limit-line=file.adb:MM` **only** when a single check is so stubborn
that the broader `--limit-subp` output is getting in the way. Typical triggers:

- You want to isolate the effect of one experiment (a new assertion, a
  contract tweak) on exactly one check, without the noise of unrelated
  failures in the same subprogram.
- A specific check keeps timing out and you want to confirm the failure
  reproduces under a single-check context before reaching for a higher level
  or considering decomposition.

```bash
gnatprove ... -j0 --output-header --limit-subp=file.adb:NN --limit-line=file.adb:MM 2>&1 | tee gnatprove-run.txt
```

The same line-number rules apply — re-locate both `NN` and `MM` before each run.

**`--limit-line` semantics**: Proves **exactly** that line, not "up to" that
line. SPARK assumes all assertions above the target line (even unproved ones).
This makes it a powerful what-if tool: insert `pragma Assert (P)` above a
failing check to test whether P would help, without yet proving P.

**Conjoined `Post` on multiple lines**: if the failing check is on a conjunct
of a multi-line postcondition (e.g. a message reported on `and then Q`),
target the line of the **first term** of the Post expression — not the
conjunct's own line. Targeting the conjunct line produces a misleading
"success" that does not mean the conjunct proved. See
[proof-debugging.md § Conjunct lines in a Post are not check lines](proof-debugging.md#conjunct-lines-in-a-post-are-not-check-lines--do-not-target-them).

Return to `--limit-subp` once the sticky check is resolved — do not accumulate
`--limit-line` runs after the focused session is done.

#### Ordering within a subprogram

1. **Top-to-bottom**: because SPARK assumes assertions above the current check
2. **Overflows first**: if you can't prove absence of overflow, nothing else matters;
   overflow fixes often introduce changes that affect downstream checks (more
   generally, this applies to all kinds of runtime errors that SPARK reports)

### Step 4: Fix, Prove, Repeat

**Do not re-run GNATprove to understand a failure.** Re-running is only
permitted after a code or contract change, or to increase proof level.
Read `gnatprove.out` first — it already contains what you need, and a
re-run without a change produces the same output at significant cost.
See [gnatprove-out.md](../gnatprove/gnatprove-out.md). *(Exception: `--explain CODE`
is a documentation lookup, not a proof run — see
[gnatprove-out.md § Explain Codes](../gnatprove/gnatprove-out.md#explain-codes).)*

**Sanity-check before re-running.** Every gnatprove run costs minutes of
wall-clock time. Before inserting an `Assert`, lemma call, or contract
change and re-running to see if it helps, verify on paper that the change
*could* discharge the failing check:

- If the prover accepted this `Assert` as true, would it close the check
  below it? (If not, the Assert is wrong even if provable.)
- Does the lemma's `Post` actually mention the fact the check needs?
- Is the loop invariant inductive — does it reference the loop index or
  otherwise tie to the loop's progress?
- For a contract tweak, does the new `Pre`/`Post` capture the missing
  information the check depends on?

If you can't talk yourself through why the change should work, neither
can the prover — fix the hypothesis first. "Throw stuff at the wall and
see what sticks" is the expensive anti-pattern: each speculative fix
costs a full gnatprove run, and most fail. When you're genuinely unsure
whether a fact is sufficient, use `--limit-line`'s what-if semantics
(see Step 3) — that's the cheap test.

**After a code or contract change**, verify the fix at `--limit-subp` scope.
This re-proves every check in the subprogram, so you simultaneously confirm
the target check improved and catch any regressions your change introduced
elsewhere. Narrow to `--limit-line` only if you are in a focused, single-check
session (see "When to narrow to `--limit-line`" above), and never add `-f`:

```bash
gnatprove ... -j0 --output-header --limit-subp=file.adb:NN 2>&1 | tee gnatprove-run.txt
```

**Line numbers are not stable across edits.** Do not assume the previous `NN`
remains valid after inserting, deleting, or moving code/comments/contracts
above the target. After any such change, you *must* re-locate the subprogram
declaration's current line number before the next run.

For each failing check, follow the decision tree in
[proof-debugging.md](proof-debugging.md).

If the check is in a loop, also follow the guidance in [loops.md](loops.md).

**Do not blame the prover prematurely.** Most proof failures are caused by:
- Wrong code (the check is correct; the code isn't)
- Missing information (needs a precondition, type bound, or intermediate assertion)
- Overwhelming context (extract a lemma to reduce context)
- Non-inductive property (needs to reference the loop index)

The prover being "too weak" is the rarest cause.

---

## Proof Level Discipline

| Level | When to use |
|-------|------------|
| 0 | Initial assessment; quick iteration |
| 1 | Normal proof work |
| 2 | When level 1 times out on checks you believe are correct |

## Reference Files

Consult these as needed:

| Topic | File |
|-------|------|
| Investigating failures | [proof-debugging.md](proof-debugging.md) |
| Writing contracts | [contracts.md](../spark/contracts.md) |
| Expression idioms | [idioms.md](../spark/idioms.md) |
| Loop invariants | [loops.md](loops.md) |
| Ghost code & lemmas | [ghost-code-and-lemmas.md](../spark/ghost-code-and-lemmas.md) |
| Overflow patterns | [overflow-patterns.md](overflow-patterns.md) |
| Floating-point proofs | [floating-point.md](floating-point.md) |
| Access types | [access-types.md](../spark/access-types.md) |
| Refactoring for proof | [refactoring-for-proof.md](refactoring-for-proof.md) |
| CLI options | [command-reference.md](../gnatprove/command-reference.md) |
| Reading proof output | [gnatprove-out.md](../gnatprove/gnatprove-out.md) |
