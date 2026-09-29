# GNATtest Command Reference

## Framework Generation Mode

```
gnattest -P <project.gpr> [switches] [filename]
```

`filename` is optional; if omitted all sources in the project are processed.

### Source Selection

| Switch | Description |
|--------|-------------|
| `-P project` | Project file (required) |
| `-U` | Process all sources from the project and all subprojects |
| `-U main` | Process only the closure of units rooted at `main` |
| `--no-subprojects` | Process sources of the root project only (ignore subprojects) |
| `-Xname=value` | Set external variable `name` to `value` in the project |
| `-eL` | Follow symbolic links when processing project files |
| `--files=file` | Read list of Ada source files to process from `file` |
| `--ignore=file` | Read list of sources to exclude from processing from `file` |
| `--strict` | Return non-zero exit code if there are any compilation errors |
| `--target=target` | Specify a cross-compilation target |
| `--RTS=runtime` | Specify the Ada runtime to use |

### Output Directories

These switches are mutually exclusive (except `--harness-dir` and `--stubs-dir`):

| Switch | Description |
|--------|-------------|
| `--harness-dir=dir` | Directory for the harness packages and `test_driver.gpr`. **Relative paths are resolved from the project's object directory** — `--harness-dir=tests/harness` lands at `<obj>/tests/harness/`, still under `obj/`. Default: `gnattest/harness` under the object dir. Best left unset; see [project-setup.md](project-setup.md) § Harness Directory. |
| `--tests-root=dir` | **Recommended default for VCS-tracked projects.** Recreate the source directory hierarchy under `dir`. **Relative paths are resolved from the object directory**, so use a `../`-prefixed path (e.g. `--tests-root=../../tests` for `Object_Dir = obj/development/`) to land bodies at `<project>/tests/` rather than `<obj>/tests/`. See [project-setup.md § Path resolution](project-setup.md#path-resolution-applies-to-a-and-b). |
| `--tests-dir=dir` | Put all test packages in one flat `dir`. Same path-resolution rules as `--tests-root`; use the same `../`-prefix pattern. Use when you want a single flat list rather than a mirrored hierarchy. |
| `--subdirs=dir` | Put test packages in a `dir` subdirectory of each source directory. Resolves relative to each `Source_Dir` — escapes `obj/` automatically without `../`s. Use when you'd rather have tests co-located with the code they test. |
| `--stubs-dir=dir` | Recreate the stub directory hierarchy under `dir` (used with `--stub`). |

See [project-setup.md](project-setup.md) for tradeoffs between these modes.

### Test Driver Behaviour

| Switch | Description |
|--------|-------------|
| `--skeleton-default=pass\|fail` | Default behaviour of unimplemented test skeletons. `fail` is the default. |
| `--passed-tests=show\|hide` | Whether to print passed tests. Default: `show`. |
| `--exit-status=on\|off` | Return non-zero exit code if any test fails. Default: `off`. If used during generation, use the same switch at execution time. |
| `--omit-sloc` | Suppress the source-location comment in skeleton bodies (useful for VCS diff noise). |
| `--no-command-line` | Omit command-line argument support from the test driver. Set automatically when the runtime does not provide it. |
| `--test-duration` | Add per-test timing to the test runner output. |
| `--test-filtering` | Add a `--routines` filter option to the generated test driver. |
| `--no-test-filtering` | Suppress test filtering support. |

### Additional Tests and Harness-Only Mode

| Switch | Description |
|--------|-------------|
| `--additional-tests=prj` | Treat sources from project `prj` as additional manual tests to include in the suite. |
| `--harness-only` | Treat argument sources as hand-written AUnit tests and generate only a harness for them. Incompatible with closure (`-U main`). |

### Separate Drivers

| Switch | Description |
|--------|-------------|
| `--separate-drivers[=unit\|test]` | Generate one executable per unit (default) or per test instead of a single monolithic driver. See [separate-drivers.md](separate-drivers.md). |

### Inheritance and LSP Testing

| Switch | Description |
|--------|-------------|
| `--inheritance-check` | Run inherited tests against descendant types (default). |
| `--no-inheritance-check` | Disable inherited test execution. |
| `--validate-type-extensions` | Also run overridden parent tests against objects of derived types (LSP check). |

### Test_Case Contracts

| Switch | Description |
|--------|-------------|
| `--test-case-only` | Generate test skeletons only for subprograms that have at least one `Test_Case` pragma or aspect. |

### Stubbing

| Switch | Description |
|--------|-------------|
| `--stub` | Generate a stub-based test framework that isolates each unit under test. Implies `--separate-drivers`. See [stubbing.md](stubbing.md). |
| `--exclude-from-stubbing=file` | Do not stub units listed in `file` (one spec filename per line). |
| `--exclude-from-stubbing:spec=file` | Same, but only when testing the unit whose spec is `spec`. |

### Experimental Features

| Switch | Description |
|--------|-------------|
| `--gen-test-vectors` | Auto-generate test input values for supported subprogram profiles. |
| `--gen-test-num=n` | Number of test inputs to generate per subprogram (default: 5). |
| `--serialized-test-dir=dir` | Directory for generated test input JSON files. |
| `--dump-test-inputs` | Dump live input values as blobs during harness execution. |
| `--minimize` | Minimise the generated test suite using structural coverage analysis. |
| `--minimization-filter=file:line` | Minimise tests only for the subprogram declared at `file:line`. |
| `--cov-level=level` | Coverage level to use for minimization (GNATcov levels). |

See [experimental-test-gen.md](experimental-test-gen.md) for usage details.

---

## Test Execution Mode

```
gnattest test_drivers.list [switches]
```

Used when separate drivers have been generated (`--separate-drivers` or `--stub`).
`test_drivers.list` is generated automatically but can be hand-edited.

| Switch | Description |
|--------|-------------|
| `--passed-tests=show\|hide` | Whether to print passed tests. |
| `--exit-status=on\|off` | Return non-zero exit code on failure. Must match the value used at generation time. |
| `--queues=n` / `-jn` | Run `n` test executables in parallel. Default: 1. |
| `--copy-environment=dir` | Copy `dir` into each temporary directory before spawning a test driver. Useful for tests that read files relative to their working directory. |
| `--subdirs=dir` | Look for test driver executables in `dir` subdirectories of the paths in `test_drivers.list`. |

---

## Global Flags

| Switch | Description |
|--------|-------------|
| `-v`, `--verbose` | Verbose output. |
| `-q`, `--quiet` | Suppress non-critical messages. |
| `--version` | Print version and exit. |
| `--help` | Print usage and exit. |

---

## GPR Package `Gnattest` Attributes

Most command-line switches can also be set in the project file under
`package Gnattest`. Command-line values override project attributes.

```ada
package Gnattest is
   for Harness_Dir      use "tests/harness";
   for Tests_Dir        use "tests/unit";   -- or Subdir / Tests_Root
   for Stubs_Dir        use "tests/stubs";
   for Skeletons_Default use "fail";        -- "pass" | "fail"
   for Additional_Tests use "extra_tests/harness.gpr";
   for Default_Stub_Exclusion_List use "no_stub.txt";
   for Stub_Exclusion_List ("my_unit.ads") use "no_stub_for_my_unit.txt";
   for Gnattest_Switches use ("--omit-sloc", "--exit-status=on");
end Gnattest;
```

`Tests_Dir`, `Subdir`, and `Tests_Root` are mutually exclusive.
