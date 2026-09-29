# GNATtest: Separate Test Drivers

## Overview

By default, gnattest generates a single monolithic test driver that runs all
tests in one executable. For larger projects or embedded targets, **separate
drivers** produce one executable per unit (or per test), enabling:

- Parallel test execution on multi-core hosts.
- Smaller executables suitable for memory-constrained embedded targets.
- Finer-grained test isolation (a crash in one driver does not abort others).
- Per-unit traceability for certification evidence.

---

## Generating Separate Drivers

```bash
gnattest -P myproject.gpr --tests-root=../../tests --separate-drivers
```

`--separate-drivers` accepts an optional value:

| Value | One executable per… |
|-------|---------------------|
| `unit` (default) | Package (all tests for a package in one binary) |
| `test` | Individual test routine (one binary per test) |

`--stub` implies `--separate-drivers=unit` automatically.

---

## The `test_drivers.list` File

GNATtest generates `<harness-dir>/test_drivers.list` — a plain-text list of
paths to the generated test driver executables (before building):

```
/path/to/obj/gnattest/harness/pkg_a_test_driver
/path/to/obj/gnattest/harness/pkg_b_test_driver
/path/to/obj/gnattest/harness/pkg_c_test_driver
```

This file is auto-generated but can be hand-edited to:
- Remove drivers for packages you don't want to run.
- Add drivers built by other means (e.g., from `--harness-only` projects).

---

## Building Separate Drivers

All drivers share `test_driver.gpr` as the root project:

```bash
gprbuild -P <obj>/gnattest/harness/test_driver.gpr
```

This builds all drivers listed in `test_drivers.list`. Alternatively, use the
generated Makefile:

```bash
make -f <obj>/gnattest/harness/Makefile
```

---

## Running Separate Drivers

### Option A: Test execution mode (recommended)

```bash
gnattest <obj>/gnattest/harness/test_drivers.list --exit-status=on
```

GNATtest spawns each driver in a temporary directory, collects results, and
prints an aggregated summary. Use `-jN` for parallel execution:

```bash
gnattest <obj>/gnattest/harness/test_drivers.list -j8 --exit-status=on
```

**`--exit-status` must match the value used at generation time.** If you used
`--exit-status=on` when generating, use it again here.

### Option B: Run drivers individually

Each driver is a standalone executable:

```bash
<obj>/gnattest/harness/pkg_a_test_driver --skeleton-default=fail
```

Useful for debugging a single driver interactively.

---

## Parallel Execution

`-jN` in test execution mode runs `N` drivers concurrently. Each driver runs
in an isolated temporary directory created by gnattest, so there is no
filesystem conflict between parallel runs.

If drivers read from or write to files relative to their working directory, use
`--copy-environment=dir` to copy `dir` into each temporary directory before
execution:

```bash
gnattest <obj>/gnattest/harness/test_drivers.list -j8 \
  --copy-environment=tests/fixtures
```

---

## Embedded Targets

Separate drivers are the standard approach for embedded testing campaigns:

1. Generate with `--separate-drivers` and the appropriate `--target` and
   `--RTS` switches.
2. Build with the cross compiler.
3. Flash and run each driver on the target (or simulator) individually.
4. Collect results manually — test execution mode (`gnattest
   test_drivers.list`) runs drivers locally and is not usable for
   cross-compiled binaries.

For target execution orchestration (flash, read UART, parse output), write a
wrapper script that invokes each driver from `test_drivers.list` and parse
the AUnit output format (`PASS`/`FAIL` lines) to aggregate results.
