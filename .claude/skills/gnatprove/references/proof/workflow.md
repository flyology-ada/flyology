# GNATprove Proof Workflow

## Overview: Scope-Based Progression

SPARK verification is fundamentally **modular**: GNATprove thinks about one subprogram
at a time, so you should too. Work at progressively narrower scope, then widen back out:

```
program → unit → subprogram → check (narrow down)
check → subprogram → unit → program (widen back, re-verify with -f)
```

## Two-Loop Architecture

A proof campaign has two loops that MUST be kept separate:

- **Strategic loop** (main agent): choosing which subprogram to work on next,
  reading proof-status.md, reviewing finished subprograms for antipatterns,
  widening scope, spotting interprocedural patterns (repeated range constraints,
  subtype opportunities, refactoring candidates).

- **Tactical loop** (subagent): reading the subprogram body, running
  `--limit-line`, inserting assertions, iterating until the subprogram proves.

**The main agent MUST NOT do tactical work inline.** When a subprogram is ready
to prove, invoke a subagent per the Strategic Loop Step 3 below.

Why this matters: tactical context (gnatprove output, line-by-line iteration)
is noise the moment a subprogram proves. The strategic loop loses nothing by
reading the now-proved code fresh and gains a clean context for the
judgment-intensive work of review and planning.

## Proof Status File

### Purpose

The proof status file (`proof-status.md`, alongside the code being proved) is the
persistent record of a proof campaign. It tracks what's proved, what's in progress,
and what obligations have been discovered. The user can review it to understand
overall progress and proof state.

### Format

***Important***: preserve the headings and comments when writing this file.

```markdown
# Proof Status: <program or unit or subprogram>
<!-- Reflect the top-level goal given. Items in the list below are moved from
     Not Started to In Progress to Reviewed and finally to Proved and Finalized. -->

Summary of final proof status.

## Proved and Finalized
<!-- Before marking an item complete here, follow the Widen Scope step
     (Strategic Loop Step 5) in workflow.md in the /gnatprove Skill.
     Remember: changes to types used by or called subprograms in a given
     subprogram may cause it to regress to an unproved state. Reproving at the
     wider scope is thus a critical means to detect these situations. -->

- [ ] Program (level, mode)
  - [ ] Unit_Name (level, mode)
    - [x] Subprogram_Name (level, mode)

## Reviewed
<!-- Before marking an item complete here, review it following the Review
     step (Strategic Loop Step 4) in workflow.md in the /gnatprove Skill -->

- [ ] Program
  - [ ] Unit_Name
    - [x] Subprogram_Name

## In Progress
<!-- A subagent executes the Tactical Loop for the subprogram below.
     It should update this section as it works. -->

- [ ] Subprogram_Name (level, mode)
  - [x] overflow check line NN
  - [ ] range check line MM -- added Assert at line KK, needs proof
  - [ ] postcondition line PP

## Not Started
<!-- Whenever a subprogram is added (due to refactoring) or discovered
     during assessment (Strategic Loop Steps 1-2), list it here so it
     is not forgotten. -->

- [ ] Subprogram_Name

## Discovered Obligations
- [ ] Prove Assert breadcrumb at file.adb:KK (added to help line MM)
- [ ] Prove Lemma_Foo body (ghost-code-and-lemmas.md)
- [ ] Add frame postcondition to Callee for Field_X (contracts.md)
```

### When to update

| Event | Action |
|-------|--------|
| Initial assessment (Strategic Loop Step 1) | Create file; add entry per subprogram with failures |
| Start working a subprogram | Move to "In Progress"; list its failing checks |
| Check proves | Mark check done |
| Add `pragma Assert` breadcrumb | Add to Discovered Obligations |
| Write a ghost lemma | Add lemma body proof to Discovered Obligations |
| Add/modify a contract | Add to Discovered Obligations (callers may need re-proof) |
| Subprogram fully proves with `--limit-subp -f` | Move to "Reviewed" |
| Strategic Loop Step 4 review complete (antipatterns checked, warnings resolved) | Move to "Proved and Finalized" after re-running `--limit-subp -f` (Strategic Loop Step 5) |
| Unit fully proves with `-u -f` | Mark unit entry in "Proved and Finalized" |

### Rules

- **Always create or load** the status file at the start of a proof campaign
- **Update after each meaningful step**, not after every GNATprove invocation
- **Keep it honest**: if a subprogram is "Proved" but you later change its callee's
  contract, move it back to "Not Started" (it needs re-verification)
- **Don't write line numbers**: as you edit files, line numbers will become
  incorrect. Use names (for subprograms) or descriptions (for messages) so you
  can find the right location again after source files are updated.

---

## Main Agent: Strategic Loop

The main agent owns these steps. It MUST NOT drop into tactical work inline —
tactical iteration belongs in a subagent (Step 3 below).

### Step 1: Assess Current State

**Tell the user**: Before doing any proof work, briefly say: "I'll run an
initial assessment to see what's failing, then ask a few strategy questions
before starting the campaign."

**Status file**: Re-read (or create) `proof-status.md` before taking any action.

**Do not re-run GNATprove to understand a failure.** Re-running is only
permitted after a code or contract change, or to increase proof level. Pipe
every run through `tee` so you can re-filter the captured output without a
new run. `gnatprove.out` is also available for deeper investigation — see
[gnatprove-out.md](../gnatprove/gnatprove-out.md). *(Exception: `--explain CODE` is a
documentation lookup, not a proof run — see
[gnatprove-out.md § Explain Codes](../gnatprove/gnatprove-out.md#explain-codes).)*

Before reading code in depth, run GNATprove to see where things stand.

```bash
gnatprove -P <project.gpr> -j0 --level=0 --output=oneline --output-header 2>&1 | tee gnatprove-run.txt
```

**Bash tool timeout**: GNATprove can run for tens of minutes — there is no
way to predict duration in advance. Always set a large `timeout` on the Bash
tool call: at minimum 300000ms (5 min) for scoped runs, and 600000ms (10 min)
or more for whole-unit or whole-program runs. If the run times out but produced
output, work with that output — a partial run is still useful and re-running
would violate the no-redundant-runs rule. Only re-run with a larger timeout if
the run produced **no output at all**. Note the timeout for future runs.

- `--output=oneline` keeps context small; one failed check per line
- Start at level 0, then try level 1 if many timeouts
- Count failures (`| wc -l`) to gauge the scope of work
- If everything proves: you're done (don't waste time reading code)

If the user gave you a specific file or subprogram, scope the initial run:
- `-u file.adb` for a single unit
- `--limit-subp=file.adb:NN` for a single subprogram

**Status file**: Create the proof status file. Add an entry under "Not Started"
for each subprogram with unproved checks. If the scope is a single subprogram,
add it to "In Progress" and list its failing checks.

**Identify subtype candidates.** Scan the failing checks for recurring range
constraints (e.g., altitude bounds, FOV bounds, resolution bounds). If you see the
same constraint appearing in 2+ preconditions, STOP and introduce a subtype before
adding more preconditions. See the "Subtype Self-Check" in [contracts.md](../spark/contracts.md).

**Assess decomposition.** For any subprogram with >30 lines or >3 levels of nesting,
you MUST evaluate whether to decompose it BEFORE annotating. See
[refactoring-for-proof.md](refactoring-for-proof.md) for criteria.

### Step 1b: Strategy Questions

Ask the user these questions now, with concrete context from the assessment.
Do not proceed to Step 2 until you have answers (or the user declines to answer).
Batch them into a single message — do not ask one at a time.

**Ask only the questions that are relevant to what the assessment found.**

| Question | Ask when | Why it matters |
|----------|----------|----------------|
| Are the numeric types and subtypes fixed, or can you modify them? If modifiable, what resources can I use to infer appropriate bounds (e.g., requirements doc, test data, comments, usage patterns)? | Overflow or range checks were found | Determines whether to use subtype refinement (preferred) or preconditions to establish bounds. Wrong choice means re-work. |

After receiving answers, summarise the constraints you'll be working under before
proceeding to Step 2.

### Step 2: Choose Starting Point

**Status file**: Re-read `proof-status.md`. Update the "In Progress" section for
the subprogram you are about to start before proceeding.

**Start at a leaf in the call graph.** Leaf subprograms have no callees (or only
callees with already-proven contracts), so their proofs depend only on their own
code and their preconditions. This avoids cascading failures from unproven callee
contracts.

After proving a leaf, move to its callers or to another leaf. Continue until
the unit is done.

### Step 2b: Sanity-Check Specifications

Before invoking a subagent, spend two minutes sanity-checking any new or
modified `Post`, ghost predicate, or loop invariant that the subagent will be
asked to discharge. The prover cannot distinguish "true but hard to prove"
from "false but hard to refute" — both surface as timeouts, uninterpretable
counterexamples, or hours of circling. A concrete example usually settles
which you have.

- **Ghost predicate or postcondition**: plug in 2–3 small concrete values (a
  3-element array, a 4×4 matrix, a state record with representative fields).
  Check that the predicate/`Post` holds where you expect it to *and fails
  where you expect it to fail*. A predicate that is always true carries no
  information; a predicate that is false on a case you intended it to cover
  is unsound.
- **Loop invariant**: trace init (first iteration) and one preservation step
  by hand. If either fails on paper, the invariant is wrong.
- **Pre/Post pair on a new subprogram**: pick one small input that satisfies
  the `Pre`, run the body by hand, check the `Post` holds on the result.

If a sanity check fails, fix the specification before invoking the subagent.
No amount of proof effort will rescue a false specification, and every
speculative gnatprove run costs non-trivial compute.

If the subprogram has no new or modified specs — you're proving existing
contracts against an unchanged body — this step is a no-op. Proceed to Step 3.

### Step 3: Invoke Subagent

Launch a subagent to execute the Tactical Loop for the chosen subprogram.
This is required, not optional — tactical iteration belongs in the subagent,
not in the main context.

Use this template for the subagent prompt (fill in the angle-bracket fields).
Be specific about **Edit scope**: the subagent's out-of-scope-edit trip-wire
(see [workflow-subagent.md § Stop and Report](workflow-subagent.md#stop-and-report--when-to-end-the-session))
fires when a fix would touch anything outside what you name here.
Under-specifying the scope forces the subagent to either bail prematurely on
legitimate edits or guess — both waste a session. "Body of `Foo` only" is
fine when you want it; so is "types in `Foo_Package`, the `Pre` of `Foo`,
and `Foo`'s body, nothing else" — just make the boundary explicit.

```
You are proving a single subprogram as part of a larger SPARK proof campaign.
Load /gnatprove and read references/workflow-subagent.md. Follow its steps
for this subprogram only.

Subprogram: <name>, declared at <file.adb>:<N>
Project: <project.gpr> (invoke via <gnatprove | alr gnatprove>)
Target level: <L>
Callee contracts: <list known postconditions, or "see proof-status.md">
Edit scope: <exactly which files, subprograms, types, or contracts the subagent
             may modify — e.g., "body of Foo only"; "types in Foo_Package, the
             Pre of Foo, and Foo's body, nothing else">
Constraints: <e.g. "use preconditions not guards", "no pragma Assume without asking">
```

Important: only one subagent should run gnatprove at a time (it assumes
exclusive access to the GPR project). You can plan the next subprogram or
do non-proof work while a subagent is running.

When the subagent finishes, move to Step 3b (Verify) before reviewing or
widening.

**Early returns are not completion claims.** The subagent may return early
because a trip-wire fired (see [workflow-subagent.md § Stop and Report](workflow-subagent.md#stop-and-report--when-to-end-the-session))
— an out-of-scope edit surfaced, a premise you supplied turned out false,
the wall-clock or attempt cap was hit, etc. An early return is a strategic
re-plan trigger, not a completion claim: skip Step 3b (there is no
proved-scope to verify) and go directly to re-planning — tighten the brief,
decompose the subprogram, rethink the premise, or pick a different
starting point — before invoking another subagent.

### Step 3b: Verify Subagent Results

After the subagent returns, verify its claim against authoritative ground
truth before moving on. Subagents report on the scope they ran — typically
`--limit-subp` — and their numbers are correct for that scope but may be
misleading at wider scope. Cases like "proved at `--limit-subp`, hundreds
unproved under `-u`" are real and expensive to discover late.

Three checks, in order:

1. **Read the invocation header in `gnatprove.out` first.** The header
   (written by `--output-header`, mandatory in every command template
   the skill teaches) records exactly what the subagent last ran: the
   command line (scope, level, flags), gnatprove version, and timestamp.
   See [gnatprove-out.md § Invocation header](../gnatprove/gnatprove-out.md#invocation-header).
   Without this, you are asking the subagent's narrative report to
   describe its own behavior — which is precisely what the header
   removes the need to do.

   Confirm from the header:
   - **Scope matches the brief** — `--limit-subp=file.adb:NN` points at
     the subprogram you assigned, or the subagent widened (usually a
     mistake; Hard Rules forbid `-u` alone).
   - **Level is at or below the target** you set — `--level=N` absent
     means level 0.
   - **No forbidden flags** — `-f` must not appear; its presence means
     the subagent broke a Hard Rule.
   - **No scope bypass** — `-u file.adb` without `--limit-subp` or
     `--limit-line` means the subagent ran the whole unit, which is
     forbidden in the tactical loop.

   If the header contradicts what the subagent's report claims
   ("I ran `--limit-subp` for `Foo`" but the header shows `-u file.adb`),
   trust the header. Plan the next step against what *actually ran*.

2. **Read the summary table and detailed report in `gnatprove.out`.**
   The last invocation's summary and per-subprogram counts are there;
   reading is free. Confirm the subagent's numbers match what the file
   actually records.

3. **If the campaign's target scope is wider than what the subagent ran,
   reconfirm at the wider scope.** Use a cache-fast run (**no `-f`**):
   the incremental cache returns correct results cheaply, and you only
   want to detect scope-mismatch failures here, not re-do fresh analysis.
   ```bash
   gnatprove ... -j0 --output-header -u file.adb 2>&1 | tee gnatprove-run.txt
   ```
   Escalate `--limit-subp` → `-u file.adb` → whole-program as the
   campaign progresses. Intermediate widenings run *without* `-f`; the
   cache handles them. The one `-f` run belongs at the widest relevant
   scope, in Step 5.

If the verification disagrees with the subagent's claim, move the
subprogram back to "In Progress" and address the new failures — either
re-invoke the subagent with the discovered checks listed or, if the
failures involve cross-subprogram interaction, handle them inline —
before Step 4. Never report a subagent's narrow claim to the user as
if it were the campaign's current state.

### Step 4: Review for Antipatterns

**Status file**: Re-read `proof-status.md`. Confirm the subprogram's checks are
all ticked off in "In Progress" before beginning review.

Before widening scope, reread the now-proved implementation against [idioms.md](../spark/idioms.md), [contracts.md](../spark/contracts.md) and [refactoring-for-proof.md](refactoring-for-proof.md). Check for:

- Recurring range constraints that should be subtypes (Subtype Self-Check in contracts.md)
- Type, contract, or code improvements that the pressure of proving obscured
- **Compiler and SPARK warnings — resolve all of them before moving to Step 5**

If improvements are significant, make them and re-prove before proceeding. Proof is a necessary condition for "done," not a sufficient one.

### Step 5: Widen Scope and Re-Verify

**Status file**: Re-read `proof-status.md` before widening. After re-verification
passes, move subprograms to "Reviewed" or "Proved and Finalized" as appropriate.

After completing all checks in a subprogram, re-verify the whole subprogram:

```bash
gnatprove ... --output-header --limit-subp=file.adb:NN -f 2>&1 | tee gnatprove-run.txt
```

**Line numbers are not stable across edits.** Do not assume the previous `NN`
remains valid after the subagent has completed its work. You *must* re-locate
the target in the current file before you run:
  - `--limit-subp=file.adb:NN` must use the subprogram declaration's current
    line number

The `-f` forces full reanalysis. This catches checks you may have missed and
verifies that your `pragma Assert` breadcrumbs themselves prove.

**`-f` is a campaign-close tool, used only from this step onward.** No
earlier step uses `-f`: not the initial assessment (Step 1), not the
subagent's tactical loop, not post-fix verification. The subagent is
explicitly forbidden from passing `-f` — see the Hard Rules in
[workflow-subagent.md](workflow-subagent.md#hard-rules--read-before-anything-else).
Its job is to flush the incremental cache and detect regressions that
incremental analysis might miss when widening scope; paying that cost on
every tactical iteration is pure waste. The first (and usually only) `-f`
run in a subprogram's proof is here, and subsequent widenings (unit,
program) use `-f` for the same regression-detection reason.

**CRITICAL**: `--limit-line` is a diagnostic tool, not a proof. It assumes all
assertions above the target line are true — including ones you haven't proved
yet. A subprogram is NOT proved until `--limit-subp` succeeds with no
`medium` or `high` messages. Similarly, a unit is not proved until `-u`
succeeds.

If `--limit-subp` fails at the target level on checks that `--limit-line`
proved:
1. **First**, try `--limit-subp` at the **next higher level**. If it succeeds,
   report the level and ask the user whether to accept it or invest effort
   reducing the level.
2. If the next level also fails, the issue is real — likely context overload
   requiring decomposition ([refactoring-for-proof.md](refactoring-for-proof.md)),
   not just a timeout.

Do NOT declare a subprogram "proved" based solely on `--limit-line` results.

Continue widening:
- After all subprograms in a unit: `gnatprove ... --output-header -u file.adb -f`
- After all units: `gnatprove ... --output-header -f` (whole program)

Use `--output=oneline` at each widening step for a quick pass/fail summary.

**IMPORTANT**: changes to types used by or called subprograms in a given
subprogram may cause it to regress to an unproved state. You **must** repeat
the proof at the wider scope using `-f` to detect these situations!

**Status file**: Move subprograms to "Proved" as they pass full re-verification.
If widening reveals new failures (e.g. a callee contract change broke a caller),
move the caller back to "In Progress" and list the new failures.

---

## When to Convert Through Stone/Bronze First

- **User says "I have SPARK code"**: Jump straight to proof
- **User says "prove this Ada code" or "translate this C to SPARK"**: Work through
  stone (SPARK legality) and bronze (flow analysis) first to reduce noise. Offer
  to commit at each level transition.

## Proof Level Discipline

| Level | When to use |
|-------|------------|
| 0 | Initial assessment; quick iteration |
| 1 | Normal proof work |
| 2 | When level 1 times out on checks you believe are correct |
| 3–4 | Not used by the main agent — the subagent stops and reports. If a subagent reports it cannot prove at level 2, **ask the user for permission** before re-invoking with a higher target level. |

## References

- [workflow-subagent.md](workflow-subagent.md) -- Tactical Loop steps for subagents
- [gnatprove-out.md](../gnatprove/gnatprove-out.md) -- Reading the gnatprove.out file
- [Levels of SPARK Use](https://docs.adacore.com/live/wave/spark2014/html/spark2014_ug/en/usage_scenarios.html#levels-of-software-assurance) -- Stone through Platinum assurance levels
- [Silver Level - Absence of Run-time Errors](https://docs.adacore.com/live/wave/spark2014/html/spark2014_ug/en/usage_scenarios.html#silver-level-absence-of-run-time-errors-aorte) -- Proving AoRTE as the standard baseline
- [Gold Level - Key Integrity Properties](https://docs.adacore.com/live/wave/spark2014/html/spark2014_ug/en/usage_scenarios.html#gold-level-proof-of-key-integrity-properties) -- Functional correctness beyond AoRTE
- [How to Speed Up GNATprove](https://docs.adacore.com/live/wave/spark2014/html/spark2014_ug/en/gnatprove.html#how-to-speed-up-a-run-of-gnatprove) -- Incremental proof, parallelism, caching
