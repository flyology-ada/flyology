<!-- Modified by flyology-ada/agents: normalized trailing whitespace. -->

# gnatprove

`gnatprove` is a complex and powerful tool with many switches that, used
incorrectly, can yield misleading or confusing results. If the user asks about
a use of `gnatprove` that's not well documented in this skill, *stop* and
direct the user to the SPARK User Guide, which is freely available from
https://docs.adacore.com/live/wave/spark2014/html/spark2014_ug/index.html.

**Never run two gnatprove instances concurrently.** `gnatprove` assumes
exclusive ownership of its output directories; parallel runs corrupt results.

Remember to always run `gnatprove` teeing its output to a file so you can
reexamine the output without re-running `gnatprove`, like this:

```bash
  gnatprove -P <project.gpr> -j0 --output-header <arguments> 2>&1 | tee gnatprove-run.txt
```

`--output-header` is mandatory. It prepends a header to `gnatprove.out`
recording the exact command line, gnatprove version, host, and timestamp —
the only reliable after-the-fact record of *how* the run was invoked. See
[gnatprove-out.md § Invocation header](gnatprove-out.md#invocation-header).

## Analysis Modes: Stone/Check, Bronze/Flow, Silver/Gold/Platinum/Proof

`gnatprove` offers three primary analysis modes (that are often, confusingly,
called "levels" and should not be conflated with the proof levels 0-4 defined
below).

1. Stone/Check. Use `--mode=check_all`: performs full SPARK legality checking.
   Only use this if the user requests it.
2. Bronze/Flow. Use `--mode=flow`. Runs a simplified check (errors only) of
   SPARK legality, then performs initialization and data-flow analysis.
   Only use this if the user requests it.
3. Silver/Gold/Platinum/Proof. Default; same as `--mode=all`. Reports all
   errors, warnings and messages from check, flow and proof. This is how
   `gnatprove` should typically be run.

Silver, Gold and Platinum are all "levels" of proof, referring to the source of
the checks that are proved. `gnatprove` makes no distinction amongst them and
indeed cannot generally tell if a given piece of code is at one of these levels
or another.

## Proof Levels

The default proof level should be selected based on the fundamental complexity
of the code to be proved:

* --level=0: Default. start here when assessing or proving code of unknown
  or low complexity
* --level=1: start here if the code is complex (deeply nested, some
  floating point)
* --level=2: start here if there are many loops with loop invariants or if
  there are many floating-point or nonlinear operations.

Increase the proof level if there are check messages *without* counterexamples
or that say the provers timed out.

Levels 3 and 4 should *never* be used without user guidance. They are sometimes
required, but generally only waste time.

## Scoping

| Flag | Effect |
|------|--------|
| `--limit-subp=file.adb:NN` | Prove only the subprogram declared at line NN. Line numbers shift after any edit; always confirm you have the right `NN`|
| `--limit-line=file.adb:NN` | Prove **exactly** checks on line NN (not "up to"). Line numbers shift after any edit; always confirm you have the right `NN` |
| `-u file.adb` | Prove only the specified file |

**Important**: `--limit-subp` line number must be the **declaration** line (where
contracts are), not the body. Filenames must not include the source directory prefix
handled by the GPR file.

**`--limit-line` semantics**: Proves exactly the check(s) at that line, assuming all
assertions above it (even unproved ones). This makes it a powerful what-if tool:
insert `pragma Assert (P)` above a failing check and use `--limit-line` to test
whether P is sufficient.

**Conjoined `Post` on multiple lines**: If the failing check is on a conjunct of
a multi-line postcondition (e.g. a message reported on `and then Q`), target the
line of the **first term** of the Post expression — not the conjunct's own line,
not the `Post =>` or comment line. Targeting the conjunct line typically yields
a misleading "success" that does not mean the conjunct proved. See
[../proof/proof-debugging.md § Conjunct lines in a Post are not check lines](../proof/proof-debugging.md#conjunct-lines-in-a-post-are-not-check-lines--do-not-target-them).

## Forcing Analysis

`gnatprove` caches analysis results locally to speed up analysis during
development. This is the default behavior and is correct and to be preferred.

Passing `-f` forces full reanalysis, bypassing the cache. This is expensive, as
all phases are performed again fully.

* during routine / iterative work: **do not** use `-f`. The subagent's tactical
  loop is explicitly forbidden from passing `-f`
  (see [workflow-subagent.md](../proof/workflow-subagent.md) Hard Rules).
* when widening scope at the end of a campaign (`--limit-subp` → `-u` → whole
  program): **do** use `-f` — cached results from the narrower run may be
  reused otherwise, masking checks in the wider scope. This is the main
  agent's job in [workflow.md § Step 5](../proof/workflow.md#step-5-widen-scope-and-re-verify).
* when confirming results at a specific proof level: `-f` is optional; it
  ensures results are not cache artifacts, but re-runs all phases at full cost

## Output Modes

`gnatprove` offers two relevant output modes:

* Pretty. Default. Pretty printed check messages, intended for command-line
  display.
* One-line. Rich check messages on a single line.

`--output=oneline` should be *your* default setting when invoking `gnatprove`.

The default `--output=pretty` is designed to help a human zero in on exactly
what part of the code a check message references. If you will present the
user with the output from `gnatprove`, prefer this format.

## Warnings

`gnatprove`'s warnings are important; do not ignore them. You can strengthen
this behavior with: `--warnings=error` which causes warnings to be treated as
errors.

## Exclusions

There are many `gnatprove` switches that you should *never* use:

* `--quiet` - suppresses too much output; leads to agent confusion
* `--proof` - soon to be deprecated; doesn't bring useful benefit
* `--provers` - always rely on configured defaults
* `--steps` - *only* if the user asks for it; has no relation to effort or
  wall-clock time
* `--counterexamples` - always rely on configured defaults
* `--memlimit` - *only* if the user asks for it; too hard to guess useful
  values
* `--timeout` - *only* if the user asks for it; rely on proof levels for
  timeouts
* `--no-global-generation` - *only* if the user asks for it; this is a
  specialized setting and will be deprecated
* `--no-loop-unrolling` - *only* if the user asks for it; complicates proof of
  short loops
* `--no-inlining` - *only* if the user asks for it; forces many more contracts,
  complicating proof

## Versions

There are two versions of `gnatprove`:

1. **SPARK Pro.** The version sold by AdaCore with professional support.
2. **SPARK FSF.** The version built by AdaCore and release through the
   Free Software Foundation.

Run `gnatprove --version` to tell which version you are running:
* **SPARK Pro**. Prints `SPARK Pro` and a version number that contains:
  YY - the release year, N - the release number (0: preview; 1: release;
  2: stabilization), w - optional: indicates a development
  wavefront, (YYYYMMDD) the build date. E.g., `SPARK Pro 27.0w (20260413)`
  designates a development wavefront for SPARK Pro release 27.0 built on
  2026-04-13.
* **SPARK FSF**. Prints `FSF` and a version number `NN.M` that matches the GCC
  release with which this FSF version of SPARK is associated.

SPARK Pro and SPARK FSF are functionally identical, however SPARK FSF usually
trails SPARK Pro by six to 18 months. SPARK Pro will thus typically have more
and newer features than SPARK FSF; these will eventually make their way into
SPARK FSF.

## Compilers

`gnatprove` does not require a `gnat` (or any other Ada) compiler (although
`gnat` is used during Phase 1 to generate data representations). However,
SPARK programs typically require `gnat` to build properly, due to SPARK
extensions to the Ada language.

When building SPARK programs, use a version of `gnat` that matches the version
of `gnatprove` to ensure compatibility. Alire will take care of this
automatically.

## Understanding `gnatprove` Output

Everything output by `gnatprove` is relevant and important. You should get all
the information you need about a `gnatprove` run from this output. Remember
that you captured the output with `| tee gnatprove-run.txt`, so you can
reexamine the output by rereading that file.

First, `gnatprove` prints information about its phases of operation.

1. `Phase 1 of 3: generation of data representation information ...`.
   In this phase, `gnatprove` generates the information it needs about the
   compilation target so that it can check that types and especially the use
   Ada representation clauses are consistent with the target. *However*, if
   this step fails, `gnatprove` will keep going.

2. `Phase 2 of 3: generation of Global contracts ...`.
   In this phase, `gnatprove` generates the Global and Depends contracts, which
   feed into flow analysis.

3. `Phase 3 of 3: flow analysis and proof ...`.
   In this phase, `gnatprove` does two things: (1) flow analysis, which checks
   dataflow and initialization; and (2) proof. Errors in (1) will prevent (2)
   from starting. But reaching this phase generally means that the code is
   valid SPARK, making this line of output from `gnatprove` meaningful.

Then, `gnatprove` prints messages. These may be:

* info: information about loop unrolling and proved checks
* warning: important information that may not be erroneous
* error: issues preventing complete/further analysis
* checks: "low", "medium" or "high" messages that may come from flow analysis
  or proof.

The level - low, medium, high - associated with a check reflects `gnatprove`'s
confidence in the correctness of a check. `high` checks, in particular, should
be treated as errors.

***Important*** an absence of error or check messages indicates successful
analysis — *but only for code that was actually analyzed*. Distinguish
"proved" from "not analyzed":

* `warning: no checks generated by GNATprove` (often with `possible reason: no
  bodies have been selected for analysis with SPARK_Mode`) means the unit was
  **not analyzed at all**. This is *not* success — there were simply no proof
  obligations. Treat it as a red flag, not a pass.
* `Success: all checks proved (N checks)` only covers the N checks that were
  generated. If you expected a body to be verified and see few or zero checks
  for it, the body was probably skipped. (**Important**: this message may
  be omitted for older versions of SPARK.) Sanity-check that N is plausible
  for what you asked to prove, and run `gnatprove` *scoped to the specific
  unit* (`-u file`) to see per-unit warnings that a whole-project run can
  bury.
* A **generic** unit is never analyzed on its own (`warning: generic
  compilation unit is not analyzed; only instantiations of the generic will be
  analyzed`). Its body's VCs are generated only through an instantiation that
  is itself in SPARK. A library-level instantiation has no enclosing
  `SPARK_Mode`, so it defaults to off and the generic body is silently skipped
  — give it the aspect explicitly:
  `package P is new G (...) with SPARK_Mode => On;`
  Then confirm checks now appear for the instantiated body.

Finally, `gnatprove` prints a footer. This contains:

```
Summary logged in /absolute/path/to/gnatprove.out
```

In newer versions of `gnatprove`, this also contains a statement declaring
successful analysis, when the analysis succeeds.

If you need more information about the last run, you can analyze
`gnatprove.out` following the instructions in
`[gnatprove-out.md](gnatprove-out.md)`. When invoked with `--output-header`
(required — see Quick Start above), `gnatprove.out` begins with an
invocation header recording the exact command line, version, host, and
timestamp. Read the header *first* whenever you open `gnatprove.out`: it
tells you which run produced the file and what switches were active, which
is the foundation for every other interpretation you do afterwards. See
[gnatprove-out.md § Invocation header](gnatprove-out.md#invocation-header).
