# Reading gnatprove.out

## What is it

`gnatprove.out` is the summary report GNATprove writes after each run. Its default
location is `<obj-dir>/gnatprove/gnatprove.out` (e.g.
`objs/release/gnatprove/gnatprove.out`). It gives a full picture of the proof run
without re-running the tool.

## File structure

The file has five sections, in order:

### 1. Invocation header

When gnatprove is run with `--output-header` (required — see
[SKILL.md](../../SKILL.md) Quick Start and
[command-reference.md § Output Control](command-reference.md#output-control)),
`gnatprove.out` begins with an invocation header that records *how* gnatprove
was run:

```
date               : 2026-04-22 12:30:29
gnatprove version  : FSF 15.0
host               : Darwin 64 bits
command line       : gnatprove -P mars_rover.gpr -j0 --output=oneline --level=2 --output-header
 Proof_Switches attribute:
   Ada: --no-subprojects
```

**Fields:**
- **`date`** -- when the run completed
- **`gnatprove version`** -- SPARK Pro release (e.g. `SPARK Pro 27.0w (20260413)`)
  or FSF release (e.g. `FSF 15.0`); matches `gnatprove --version`
- **`host`** -- the machine gnatprove ran on
- **`command line`** -- the *literal* command-line arguments the invocation
  received. This is what was passed to `gnatprove` (or `alr gnatprove`); it
  includes the project file, scope flags (`--limit-subp`, `--limit-line`,
  `-u`), `--level`, `--mode`, `-f`, `-j`, `--output=*`, and any other
  switches — exactly as typed.
- **`Proof_Switches attribute`** -- switches coming from the GPR project
  file's `Proof_Switches` attribute, *not* the command line. Present only
  when the project declares them. These also influence the run and are not
  visible from the invocation alone.

**How to use:** Read the header *first* whenever you open `gnatprove.out`.
Every interpretation downstream — what scope the run covered, what level it
used, whether `-f` was passed, which flags the GPR file added — depends on
knowing what was invoked. The header is the authoritative record.

**Primary use case: verifying a subagent's run.** The main agent cannot
observe the subagent's Bash call directly. After the subagent returns, the
main agent reads this header to confirm exactly what was run — the scope
(`--limit-subp=file.adb:NN` vs. `-u` vs. whole program), the proof level,
and whether forbidden switches (`-f` in the tactical loop) slipped through.
This is the foundation of
[workflow.md § Step 3b: Verify Subagent Results](../proof/workflow.md#step-3b-verify-subagent-results).

**Secondary use case: reconstructing a prior run.** A returning user (or a
future session) opening `gnatprove.out` sees the command that produced it.
Without the header, the file is a report whose provenance must be guessed.

### 2. Summary table

---SPARK Analysis results        Total         Flow   Provers   Justified   Unproved

Data Dependencies                49           49         .           .          .
Run-time Checks                  12            .        12           .          .
Assertions                        1            .         .           .          1
...

Total                           161    160 (99%)         .           .     1 (1%)

**Columns:**
- **Total** -- number of verification conditions (VCs) in this category
- **Flow** -- discharged by flow analysis (data dependencies, initialization, termination)
- **Provers** -- discharged by an automatic prover (CVC5, Z3, Alt-Ergo)
- **Justified** -- suppressed by `pragma Annotate` (manually justified)
- **Unproved** -- not discharged by any means

**Rows** (categories of checks):
| Row | What it covers |
|-----|---------------|
| Data Dependencies | Global / Depends contracts |
| Flow Dependencies | Depends contracts (information flow) |
| Initialization | Variables read before written |
| Non-Aliasing | No illegal aliasing of parameters |
| Run-time Checks | Overflow, range, index, division-by-zero, etc. |
| Assertions | `pragma Assert`, `Assert_And_Cut`, user assertions |
| Functional Contracts | Postconditions (`Post`), contract cases |
| LSP Verification | Liskov substitution (tagged type contracts) |
| Termination | Loop and subprogram termination |
| Concurrency | Race-freedom, deadlock-freedom |

**How to use:** Look at the Unproved column. Each nonzero entry tells you
which *category* of check failed. This guides your strategy: an unproved
run-time check likely needs a type bound or precondition, while an unproved
assertion needs a proof hint or code restructuring.

### 3. Max steps / hardest checks

max steps used for successful proof: 1234

============================
Most difficult proved checks


This shows the highest step count among proved VCs and lists the checks that
were hardest for the prover. Checks near the step limit are fragile -- small
code changes may cause them to fail. If you see checks here that are close to
the step limit for the current `--level`, note them as proof stability risks.

If the section says "No check found with max time greater than 1 second", the
proof run was easy and all VCs were dispatched quickly.

### 4. Detailed analysis report

Analyzed N unit(s)
in unit , X subprograms and packages out of Y analyzed
Pkg.Subprogram at file.ads:NN flow analyzed (...) and proved (K checks)
Pkg.Other at file.adb:MM flow analyzed (...) and not proved, J checks out of K proved

One line per subprogram/package. Each line says:
- **"proved (K checks)"** -- all K VCs discharged
- **"not proved, J checks out of K proved"** -- J of K discharged; K-J remain
- **"skipped; body is SPARK_Mode => Off"** -- not analyzed (non-SPARK code)

**How to use:** Search for `not proved` to find the exact subprograms with
remaining work. The `at file.adb:NN` tells you the declaration line, which is
the value to pass to `--limit-subp`.

Lines for generic instantiations (e.g. `Entity_Config_Maps.Formal_Model.K.Add at
spark-containers-functional-vectors.ads:287, instantiated at ...`) are library
code from SPARK containers. These are always either "proved" or "skipped" and
can be ignored unless they show failures.

### 5. EOF

The file ends after the last detailed entry. There is no trailing summary.

## Quick-reference: extracting actionable information

| Question | How to answer from gnatprove.out |
|----------|--------------------------------|
| What command produced this file? | Invocation header, `command line` field |
| What scope did the run cover? | Invocation header, `command line` — look for `--limit-subp`, `--limit-line`, `-u`, or absence of all three (whole program) |
| What proof level was used? | Invocation header, `command line` — `--level=N` (absent = 0) |
| Was `-f` passed? | Invocation header, `command line` — look for `-f` or `--force` |
| What gnatprove version ran? | Invocation header, `gnatprove version` field |
| Did the GPR file add switches? | Invocation header, `Proof_Switches attribute` block (if present) |
| When did the run complete? | Invocation header, `date` field |
| Are there any unproved checks? | Summary table, Unproved column |
| How many and what kind? | Summary table rows with nonzero Unproved |
| Which subprograms have failures? | Search for `not proved` in detailed report |
| What file/line to investigate? | The `at file.adb:NN` on the `not proved` line |
| Is the proof fragile? | Check "max steps" and "most difficult" sections |
| What was analyzed? | "Analyzed N unit(s)" line and per-unit breakdown |
| What was skipped? | Lines containing "skipped; body is SPARK_Mode => Off" |

## Explain Codes

Some GNATprove messages include an **explain code** — a short tag identifying
the specific check or message kind. When output contains one, run:

```bash
gnatprove --explain CODE
```

This prints a detailed explanation of the message, including what causes it and
how to address it. It is a documentation lookup — it does not invoke the prover
and completes in milliseconds. It is not subject to the no-redundant-runs rule.

## Workflow integration

After opening `gnatprove.out`:

1. **Read the invocation header first** — scope, level, `-f`, version. Every
   interpretation below depends on knowing what was run. If the header is
   missing, the last run was made without `--output-header` and the file's
   provenance is unknown; do not draw conclusions about "what's left to
   prove" from it, and ensure the *next* run includes `--output-header`
   (the skill's templates mandate it).
2. Note the unproved count and categories from the summary table
3. Grep for `not proved` in the detailed section to get the subprogram list
4. For each unproved subprogram, use `--limit-subp=file.adb:NN` (using the
    declaration line from the report) to get per-check details
5. Follow the investigation workflow in [proof-debugging.md](../proof/proof-debugging.md)
6. Update the proof status file with findings
