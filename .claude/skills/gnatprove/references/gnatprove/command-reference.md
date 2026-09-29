# GNATprove Command-Line Reference

## Invocation

```bash
gnatprove -P project.gpr [switches] [-cargs compiler_switches]
```

## Proof Levels

| Level | Provers | Timeout | Memlimit | Counterexamples |
|-------|---------|---------|----------|-----------------|
| 0 | cvc5 | 1s | 1000MB | off |
| 1 | cvc5, z3, altergo | 1s | 1000MB | off |
| 2 | cvc5, z3, altergo | 5s | 1000MB | on |
| 3 | cvc5, z3, altergo | 20s | 2000MB | on |
| 4 | cvc5, z3, altergo | 60s | 2000MB | on |

Start at level 0-1. Level 2 is the practical maximum for iterative work.
Levels 3 and 4 should *never* be used without user guidance. They are sometimes
required, but generally only waste time.

## Mode Selection

| Flag | What it checks |
|------|---------------|
| `--mode=check` | Basic SPARK checks (errors only) |
| `--mode=check_all` | Full SPARK legality checking (errors, warnings and messages) |
| `--mode=flow` | check (report errors only) + Initialization & data flow |
| `--mode=prove` | check (report errors only) + flow (report errors only) + proof |
| `--mode=all` | all errors, warnings and messages from check, flow and proof |

**Aliases** (methodology names): `stone` = `check_all`, `bronze` = `flow`,
`silver` = `gold` = `all`. Note that `silver` and `gold` are **identical** --
both run full flow + proof. The stone/bronze/silver/gold terminology describes
your *proof objectives*, not distinct analysis modes.

## Scoping

| Flag | Effect |
|------|--------|
| `--limit-subp=file.adb:NN` | Prove only the subprogram declared at line NN |
| `--limit-line=file.adb:NN` | Prove **exactly** checks on line NN (not "up to") |
| `--limit-name=Name` | Prove only the named subprogram |
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

### `--limit-subp` and nested subprograms

Covers a nested subprogram only if that one is **inlined** (contextual analysis,
UG § *Contextual Analysis of Subprograms Without Contracts*); otherwise it is its
own proof target and the enclosing run merely assumes its contract.

- **With a contract** (`Pre`, `Post`, `Global`, `Depends`, `Contract_Cases`):
  always its own target. Enumerating these and giving each its own
  `--limit-subp` at its own declaration line establishes coverage.
- **Without a contract**: not decidable from the source — recursion, deep-typed
  parameters, nested declarations, calls in an assertion or a potentially
  unevaluated context, etc. also block inlining. Get the truth by analyzing
  the caller: `info: analyzing call to "X" in context` = folded into caller,
  otherwise = its own target. `--info` gives the reason inlining was refused.

A nested subprogram's absence from a `--limit-subp` run is uninformative — an
inlined one and a separate target that the run simply did not select look
identical. `--no-inlining` makes every local subprogram its own target.

## Output Control

| Flag | Effect |
|------|--------|
| `--output=oneline` | One check per line (good for status/counting) |
| `--output=brief` | Shorter messages |
| `--output-header` | **Mandatory for every run.** Prepends an invocation header (date, version, host, command line, `Proof_Switches`) to `gnatprove.out`. The only reliable after-the-fact record of how gnatprove was invoked; the main agent reads it to verify what a subagent ran. See [gnatprove-out.md § Invocation header](gnatprove-out.md#invocation-header). |
| `--report=fail` | Only unproved checks (default) |
| `--report=all` | Proved and unproved (mainly for user reassurance) |
| `--report=provers` | Include which prover solved each check |
| `--report=statistics` | Timing and statistics |
| `--info` | Output informational messages |
| `--counterexamples=on/off` | Toggle counterexample generation |
| `--warnings=off/continue/error` | Warning handling |
| `--checks-as-errors=on/off` | Treat check failures as errors |

**Preferred output modes**: Use `--output=oneline` for quick assessment and failure
counting. Use default output (no `--output` flag) when working check-by-check with
`--limit-line`, as the verbose messages include useful context.

## Performance

| Flag | Effect |
|------|--------|
| `-j N` | Parallel processes (0 = all cores) |
| `--timeout=N` | Per-check prover timeout in seconds |
| `--steps=N` | Max proof steps (more reproducible than timeout) |
| `--memlimit=N` | Prover memory limit in MB |
| `--no-loop-unrolling` | Skip automatic loop unrolling |
| `--no-inlining` | Skip contextual analysis inlining |
| `--replay` | Reuse stored proofs (slightly elevated limits; user limits ignored) |

## Other

| Flag | Effect |
|------|--------|
| `-f` | Force full reanalysis. Used **only** during the main agent's closing widening pass (workflow.md Step 5 and onward — subprogram → unit → program). **Forbidden in the subagent's tactical loop** and in any iterative work: forcing a full recompile + flow reanalysis on every run is pure waste. |
| `-k` | Continue past errors |
| `--clean` | Remove intermediate files and exit |
| `--explain CODE` | Print a detailed explanation of the check or message identified by the given explain code. **Not a proof run** — does not invoke the prover, completes in milliseconds. Use freely when output contains an explain code; not subject to the no-redundant-runs rule. |

## Speed Tips

1. Use `-j0` (all cores) unless the user has specified a parallelism limit
2. Start at `--level=0`, increase only when needed
3. Use `--limit-subp` to focus on one subprogram
4. `--no-loop-unrolling` avoids expensive expansions
5. `--counterexamples=off` at low levels (saves time)
6. `--replay` for quick re-verification after small changes
7. `--steps` over `--timeout` for reproducibility across machines

## References

- [Command Line Invocation](https://docs.adacore.com/live/wave/spark2014/html/spark2014_ug/en/appendix/command_line_invocation.html) -- Complete GNATprove switch reference
- [Running GNATprove from the Command Line](https://docs.adacore.com/live/wave/spark2014/html/spark2014_ug/en/gnatprove.html#running-gnatprove-from-the-command-line) -- Invocation modes and common usage
- [Project Attributes](https://docs.adacore.com/live/wave/spark2014/html/spark2014_ug/en/appendix/project_attributes.html) -- GPR attributes controlling GNATprove behavior
