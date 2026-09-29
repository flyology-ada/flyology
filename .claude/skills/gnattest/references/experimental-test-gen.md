<!-- Modified by flyology-ada/agents: removed unavailable fuzzing guidance. -->

# GNATtest: Experimental Test Input Generation

> **These features are experimental.** The interface (switches, JSON format,
> runtime API) is subject to change without notice between GNATdas releases.
> Do not rely on this format for long-lived test artefacts.

---

## Overview

GNATtest can automatically generate test input values for subprograms whose
parameter types it can analyse statically. Generated inputs are stored as JSON
files and compiled into AUnit test cases alongside hand-written skeletons.

## Prerequisites: Building the Test Generation Runtime

Value generation for Ada types requires a runtime project (`tgen_rts`) that
must be built and installed before gnattest can use `--gen-test-vectors`.

```bash
# Copy sources from the GNATdas installation
cp -r <GNATdas_install_dir>/share/tgen/tgen_rts /tmp/tgen_rts_src

# Build
cd /tmp/tgen_rts_src
gprbuild -P tgen_rts.gpr

# Install
gprinstall -p -P tgen_rts.gpr --prefix=/tmp/tgen_rts_install

# Make available to other tools
export GPR_PROJECT_PATH=/tmp/tgen_rts_install/share/gpr:$GPR_PROJECT_PATH
```

Add the `GPR_PROJECT_PATH` export to your shell profile or CI environment.

---

## Generating Test Vectors

```bash
gnattest -P myproject.gpr \
  --tests-root=../../tests \
  --gen-test-vectors \
  --gen-test-num=10
```

| Switch | Description |
|--------|-------------|
| `--gen-test-vectors` | Enable automatic test input generation |
| `--gen-test-num=n` | Number of test inputs to generate per subprogram (default: 5) |
| `--serialized-test-dir=dir` | Directory for generated JSON input files (default: `<obj>/gnattest/tests/JSON_Tests`) |

### What is generated

- JSON files under `<obj>/gnattest/tests/JSON_Tests/` — one per subprogram,
  containing the generated input values.
- Ada source files `*-test_data-test_<subp>_<hash>.ad[bs]` containing AUnit
  test cases that load and execute the JSON inputs.

The JSON files are **preserved** across gnattest reruns — you can edit them to
add expected return values or specific corner cases. The Ada source files are
regenerated each run (even without `--gen-test-vectors`), incorporating any
JSON changes.

### Supported parameter types

Test input generation works when ALL `in` and `in out` parameters are:
- Scalar types (integers, enumerations, floats, fixed-point)
- Composite types (records, arrays) with scalar components
- Unconstrained array types (random length 0–10, random bounds)
- Record types with discriminants (all variants are explored)

Generation is **not supported** for subprograms with `in`/`in out` parameters
that are:
- Access types or types with access sub-components
- Subprogram access types
- Limited types
- Tagged types (`in` or `out`)
- Private types of nested packages

Unsupported subprograms are silently skipped.

---

## Dumping Live Inputs

```bash
gnattest -P myproject.gpr \
  --tests-root=../../tests \
  --dump-test-inputs
```

With `--dump-test-inputs`, the harness records the actual input values passed to
each subprogram during test execution as binary blobs. These blobs can be fed
back into GNATtest as additional test vectors.

This is useful for capturing interesting inputs found by randomized testing
that you want to promote into the permanent test suite.

---

## Test Suite Minimization

After running tests with coverage enabled, gnattest can remove test cases that
are structurally redundant (covered by other cases):

```bash
gnattest -P myproject.gpr \
  --tests-root=../../tests \
  --minimize \
  --cov-level=stmt+decision
```

| Switch | Description |
|--------|-------------|
| `--minimize` | Remove test cases that add no new structural coverage |
| `--minimization-filter=file:line` | Only minimise tests for the subprogram declared at `file:line` (`file` must be a simple filename, no path) |
| `--cov-level=level` | Coverage level to use as the minimization criterion (GNATcov levels: `stmt`, `stmt+decision`, `stmt+mcdc`) |

Minimization requires GNATcoverage traces from a prior test run. Run the full
test suite under `gnatcov run` first, then invoke GNATtest with `--minimize`.
