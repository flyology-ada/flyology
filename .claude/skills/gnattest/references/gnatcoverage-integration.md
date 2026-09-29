# GNATtest: Integration with GNATcoverage

## Overview

When `--separate-drivers` is used (including `--stub`), gnattest generates a
`Makefile` alongside `test_driver.gpr`. This Makefile automates building,
running under GNATcoverage instrumentation, and aggregating coverage results.

GNATcoverage (`gnatcov`) must be installed and on `PATH` for the coverage
targets to work.

---

## Generated Makefile Targets

| Target | Description |
|--------|-------------|
| `all` | Build all test drivers |
| `run` | Build and run all test drivers (without coverage) |
| `coverage` | Full coverage pipeline: build → run under gnatcov → aggregate traces |
| `clean` | Remove build artefacts |

---

## Running the Coverage Pipeline

```bash
make -f <obj>/gnattest/harness/Makefile coverage
```

This:
1. Builds all test drivers with instrumentation for coverage.
2. Runs each driver under `gnatcov run`, producing a `.srctrace` file.
3. Calls `gnatcov coverage` to analyse each trace.
4. Calls `gnatcov aggregate-coverage` to merge all traces into a combined report.

The final report is written to the object directory and shows statement,
decision, or MC/DC coverage depending on the `--cov-level` used.

---

## Specifying Coverage Level

Pass `--cov-level` to gnattest at generation time to set the coverage level
baked into the Makefile:

```bash
gnattest -P myproject.gpr \
  --tests-root=../../tests \
  --separate-drivers \
  --cov-level=stmt+decision
```

Common levels (see `gnatcov help` for the full list):

| Level | Description |
|-------|-------------|
| `stmt` | Statement coverage |
| `stmt+decision` | Statement + decision (branch) coverage |
| `stmt+mcdc` | Statement + Modified Condition/Decision Coverage (DO-178C) |

If `--cov-level` is not set, the Makefile uses a default level; check the
generated Makefile to see what was selected.

---

## Using GNATcoverage Without the Makefile

If you prefer to drive coverage manually:

```bash
# Build with coverage instrumentation
gprbuild -P <obj>/gnattest/harness/test_driver.gpr \
  --src-subdirs=gnatcov-instr --implicit-with=gnatcov_rts

# Run each driver under gnatcov
gnatcov run --level=stmt+decision <obj>/gnattest/harness/pkg_a_test_driver \
  -o pkg_a.srctrace

# Produce a per-driver coverage report
gnatcov coverage --level=stmt+decision --annotate=xcov \
  -P myproject.gpr pkg_a.srctrace

# Aggregate all traces
gnatcov coverage --level=stmt+decision --annotate=xcov \
  -P myproject.gpr *.srctrace
```

---

## Test Minimization (Experimental)

GNATtest can minimise the test suite to remove redundant tests using coverage
analysis. See [experimental-test-gen.md](experimental-test-gen.md) for the
`--minimize` and `--minimization-filter` switches.
