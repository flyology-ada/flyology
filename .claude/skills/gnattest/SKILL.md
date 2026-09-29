---
name: gnattest
description: This skill should be used when the user wants to "generate unit tests", "run gnattest", "create test skeletons", "build a test harness", "write AUnit tests", "add tests to Ada code", "run a testing campaign", or is otherwise working with GNATtest for Ada unit testing.
license: Apache-2.0
metadata:
  version: "0.1.0"
  source_repository: "https://github.com/AdaCore/skills"
  source_revision: "ab0360b0adcb0c0831bc2836aaa4d4bcfdc9cf74"
  modified_by: "flyology-ada/agents"
---

# GNATtest Unit Testing Skill

## Locating GNATtest

Unless the user has already told you how to invoke gnattest, determine the right
invocation in this order:

1. **Check for an `alire.toml` in the project root.** Its presence means the
   project is an Alire crate. There is **no** `alr gnattest` subcommand; use:

   ```bash
   PATH="$HOME/.alire/bin:$PATH" alr exec -- gnattest -P <project.gpr> ...
   ```

   `alr exec` runs `gnattest` inside the crate's resolved environment
   (including `GPR_PROJECT_PATH` for multi-crate projects). The `PATH` prefix
   is required because `gnattest` is installed via `alr install gnattest` into
   `$HOME/.alire/bin/`, which is not on `PATH` automatically — not even under
   `alr exec`. Without it, the call fails with `Executable not found in
   PATH`. As an alternative, invoke gnattest by absolute path:
   `alr exec -- "$HOME/.alire/bin/gnattest" -P <project.gpr> ...`. See the
   alire skill's `alire-install.md` and `testing.md` for full details.

2. **Check if `gnattest` is already on `PATH`.** Run `which gnattest`. If found,
   use it directly.

3. **Ask the user.** GNAT Pro installations (commonly under `/usr/gnat` or
   `/opt/gnat`) may require environment setup beyond a binary path. If gnattest
   is not on `PATH` and there's no `alire.toml`, don't guess — ask the user how
   they want to configure the environment.

## Quick Start

GNATtest works in two phases: **generate** the test framework, then **build and
run** it.

### Phase 1 — Generate the test framework

```bash
gnattest -P <project.gpr> --tests-root=../../tests
```

(The `../../` count is the depth of your `Object_Dir`. For
`Object_Dir = obj/development/` (Alire default, 2 levels), use
`--tests-root=../../tests`. For `Object_Dir = obj/` (1 level), use
`--tests-root=../tests`. The destination is always
`<project_root>/tests/` — a sibling of `src/`. See
[project-setup.md § Path resolution](references/project-setup.md#path-resolution-applies-to-a-and-b).)

This produces two kinds of output:

- **Test harness** under `<obj>/gnattest/harness/` — fully auto-generated
  and re-created on every run; lives in the object directory and is
  gitignored along with the rest of the build tree.
- **Test skeleton bodies** under `<project_root>/tests/` (mirrored
  hierarchy: `tests/src/my_unit-test_data-tests.adb` mirroring
  `src/my_unit.ads`) — preserved across re-runs; this is where you
  write your tests, and where they need to live to be tracked by
  version control.

**Why `--tests-root` with a `../`-prefixed path.** `--tests-root` (and
`--tests-dir`) resolve relative paths against the **object directory**,
not the CWD. A bare `--tests-root=tests` therefore puts bodies at
`<obj>/tests/`, which is gitignored along with the rest of `obj/` — and
`gprclean` will delete them. Prepending `../` per level of `Object_Dir`
escapes the object directory and lands the mirror at the project root.
The `--subdirs=<name>` option escapes `obj/` automatically (resolves
relative to each `Source_Dir`) and is fine if you'd rather have tests
co-located with sources; see [project-setup.md](references/project-setup.md)
for the trade-off.

### Phase 2 — Build and run

```bash
gprbuild -P <obj>/gnattest/harness/test_driver.gpr
<obj>/gnattest/harness/test_runner
```

Replace `<obj>` with your project's object directory (whatever
`Object_Dir` your `.gpr` defines — typically `obj/`).

Unimplemented skeletons report "test not implemented" and fail by default.
Pass `--skeleton-default=pass` to the test runner to treat them as passed.

**AUnit prerequisite:** the harness depends on `aunit.gpr`. In Alire projects
run `alr with aunit` first. In non-Alire projects, AUnit must be on
`GPR_PROJECT_PATH`. Build will fail with a project-not-found error if it is
missing.

## Two Modes

| Mode | Invocation | Purpose |
|------|-----------|---------|
| Framework generation | `gnattest -P project.gpr [opts]` | Generate or update test skeletons and harness |
| Test execution | `gnattest test_drivers.list [opts]` | Run separate test driver executables and aggregate results |

Test execution mode is used together with `--separate-drivers` or `--stub`
workflows where multiple executables are produced. See
[separate-drivers.md](references/separate-drivers.md).

## Core Principles

- **Harness is disposable; skeleton bodies are yours.** The harness directory
  (except `gnattest_common.gpr`) is regenerated on every run — never edit those
  files. Test skeleton *bodies* (`*-test_data-tests.adb`) and
  `*-test_data.adb` files are never overwritten and belong in version control.
  Test skeleton *specs* (`*-test_data-tests.ads`) are regenerated — do not
  commit them. See [workflow.md](references/workflow.md) for the full VCS rules.

- **Never remove the comment section markers in skeleton bodies.** GNATtest
  uses `--  begin read only` / `--  end read only` markers to locate and
  preserve existing test code during regeneration. Removing them causes the
  tool to regenerate a fresh (empty) skeleton, silently discarding your tests.

- **Project file is mandatory.** GNATtest always requires `-P project.gpr`.
  It cannot operate on loose source files.

- **Default output goes under `obj/`.** If `obj/` is gitignored — it usually
  is — the skeleton bodies you write will not be tracked by version control,
  and `gprclean` will delete them. Pass `--tests-root=<n>/tests` (where
  `<n>` is enough `../`s to escape `Object_Dir`) to land the mirrored
  hierarchy at `<project>/tests/`. **Relative paths given to
  `--tests-dir`, `--tests-root`, and `--harness-dir` resolve against the
  object directory**, so without the `../` prefix those flags don't
  escape `obj/`. (`--subdirs` resolves relative to each `Source_Dir`
  instead and escapes `obj/` automatically; use it if you'd rather
  co-locate tests with the code they test.) See
  [project-setup.md](references/project-setup.md).

- **`gnattest_common.gpr` is the right place to customise harness build
  options.** It is created once and never overwritten. Edit it to add compiler
  flags, linker options, or project-level settings needed to compile the tests.

## Reference Files

| Topic | File | When to read |
|-------|------|-------------|
| CLI switches (both modes) | [command-reference.md](references/command-reference.md) | Looking up any gnattest flag or GPR attribute |
| End-to-end workflow & VCS rules | [workflow.md](references/workflow.md) | Setting up a testing campaign from scratch |
| Writing test skeletons | [test-skeletons.md](references/test-skeletons.md) | Implementing test routines, Set_Up/Tear_Down, regeneration rules |
| Directory layout & GPR config | [project-setup.md](references/project-setup.md) | Controlling where generated files go and driver project compilation options |
| Library projects with restricted `Library_Interface` | [library-projects.md](references/library-projects.md) | Project under test is a library project whose `Library_Interface` does not cover every unit you want to test |
| Tagged types & inheritance | [tagged-types-and-inheritance.md](references/tagged-types-and-inheritance.md) | Testing primitives, LSP substitutability validation |
| Test_Case contracts | [contracts.md](references/contracts.md) | Test_Case pragma/aspect, Nominal vs. Robustness mode |
| Stub-based isolation (tutorial) | [stubbing.md](references/stubbing.md) | Isolating units under test from their dependencies |
| Separate test drivers | [separate-drivers.md](references/separate-drivers.md) | Per-unit/per-test executables, parallel runs, embedded targets |
| GNATcoverage integration | [gnatcoverage-integration.md](references/gnatcoverage-integration.md) | Coverage-driven testing with GNATcov |
| Auto test-input generation | [experimental-test-gen.md](references/experimental-test-gen.md) | Experimental GNATtest vector generation and minimization |
