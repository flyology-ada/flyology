# GNATtest End-to-End Workflow

## Prerequisites Checklist

Before running gnattest:

1. **AUnit is available.** In Alire projects: `alr with aunit`. In non-Alire
   projects: `aunit.gpr` must be on `GPR_PROJECT_PATH`. Without this, the
   harness will not compile.
2. **The project file compiles cleanly.** GNATtest semantically analyses
   sources; compilation errors prevent skeleton generation.
3. **Decide on a directory layout.** Choose between `--tests-dir`,
   `--subdirs`, or `--tests-root` before the first run — changing it later
   leaves orphaned test files. See [project-setup.md](project-setup.md).

---

## Step 1 — Initial Skeleton Generation

> **Library projects:** if your project under test is a library project
> (`for Library_Name use ...`) with a restricted `Library_Interface`,
> read [library-projects.md](library-projects.md) **before** running
> gnattest. Pointing gnattest at the production GPR will produce a
> harness that fails to build with `Unit ... cannot import unit ...
> it is not part of the interfaces of its project ...`. The fix is a
> sibling test-only GPR; the rest of this workflow then applies
> unchanged once you point `-P` at the sibling instead.

Run gnattest across the full project to generate all skeletons at once:

```bash
gnattest -P myproject.gpr --tests-root=../../tests
```

Or, if using Alire (see [SKILL.md § Locating GNATtest](../SKILL.md#locating-gnattest)
for why the `PATH` prefix is required and why there is no `alr gnattest`
subcommand):

```bash
PATH="$HOME/.alire/bin:$PATH" alr exec -- gnattest -P myproject.gpr --tests-root=../../tests
```

GNATtest reports how many test packages were created or updated.

`--tests-root=../../tests` lands the skeleton bodies under
`<project_root>/tests/` as a mirrored hierarchy
(`tests/src/my_unit-test_data-tests.adb` mirroring `src/my_unit.ads`).
The `../../` count is the depth of `Object_Dir` (Alire default
`obj/development/` is 2 levels; for `obj/` use `../tests`; for
`obj/test/development/` use `../../../tests`). The harness goes to
`<obj>/gnattest/harness/` and is regenerated on every run.

**Why the `../../` prefix?** `--tests-root` (and `--tests-dir`) resolve
relative paths against the **object directory**, not the CWD. A bare
`--tests-root=tests` puts bodies at `<obj>/tests/` — still under `obj/`
and gitignored. The `../../` climbs out of `Object_Dir` to land the
mirror at the project root. (`--subdirs=<name>` resolves relative to
each `Source_Dir` instead and escapes `obj/` automatically; use it if
you'd rather have tests beside the code they test.)

**Scope options:**
- Default: all sources in the project.
- `-U` : all sources including subprojects.
- `--no-subprojects` : root project sources only.
- Single file: `gnattest -P myproject.gpr --tests-root=../../tests src/my_unit.ads`

---

## Step 2 — Inspect the Generated Structure

```
src/
  my_unit.ads
  my_unit.adb

tests/                              ← created by --tests-root=../../tests
  src/                              ← mirror of source dir layout
    my_unit-test_data.ads           ← regenerated spec; do not commit
    my_unit-test_data.adb           ← Set_Up / Tear_Down — yours to edit
    my_unit-test_data-tests.ads     ← regenerated spec; do not commit
    my_unit-test_data-tests.adb     ← YOUR tests; preserve comment markers

<obj>/                              ← typically obj/ — fully gitignored
  gnattest/
    harness/                        ← auto-generated; regenerated each run
      test_driver.gpr
      gnattest_common.gpr           ← created once; never overwritten
      suite_*.ads / .adb
      test_runner.adb
```

This layout assumes `--tests-root=../../tests` as shown in Step 1.
Without it, the skeleton bodies land under `<obj>/gnattest/tests/`
instead and are gitignored.

**`gnattest_common.gpr`** is where you add compiler flags, extra source dirs,
or any build customisation needed to compile the tests. Edit it freely — it is
never overwritten.

---

## Step 3 — Build the Test Driver

```bash
gprbuild -P <obj>/gnattest/harness/test_driver.gpr
```

(Replace `<obj>` with your project's `Object_Dir` — typically `obj/`.)

Fix any build errors in `gnattest_common.gpr` or test data packages before
proceeding. Do not edit auto-generated harness files.

### Ada language version override

If your project requires Ada 2022 (or any non-default version — `declare`
expressions, `'Reduce`, etc.), the harness build will fail with syntax
errors. The auto-generated `test_driver.gpr` hardcodes `-gnat2012`:

```ada
--  excerpt from the auto-generated test_driver.gpr
package Compiler extends Gnattest_Common.Compiler is
   for Default_Switches ("Ada") use
     Gnattest_Common.Compiler'Default_Switches ("Ada") & ("-gnat2012");
end Compiler;
```

The `-gnat2012` is **appended after** whatever you set in
`gnattest_common.gpr` — last flag wins, so adding `-gnat2022` in
`gnattest_common.gpr` does **not** work. Override at gprbuild time
instead:

```bash
gprbuild -P <obj>/gnattest/harness/test_driver.gpr -cargs:Ada -gnat2022
```

`-cargs:Ada` switches go after every project-file switch on the
compiler command line, so the trailing `-gnat2022` wins. This is the
canonical fix: per-build, no file edits, no sed-after-regen. (For Alire
projects, run the same command under `alr exec --`.)

Use the same pattern for any other language-version flag (`-gnat2020`,
`-gnat05`, etc.) or for any other compiler switch that gnattest's
hardcoded last-position switch is fighting.

---

## Step 4 — Run the Tests

```bash
<obj>/gnattest/harness/test_runner
```

Initial output will list all tests as "FAIL: test not implemented". This is
expected — every skeleton starts as a failing stub.

Useful runtime options (accepted by the test runner directly):
- `--skeleton-default=pass` — treat unimplemented tests as passed
- `--routines=My_Package.Test_Foo` — run a single test (requires
  `--test-filtering` at generation time)

---

## Step 5 — Implement Skeleton Bodies

Open each `*-test_data-tests.adb` file and fill in the test routines. See
[test-skeletons.md](test-skeletons.md) for the anatomy of a skeleton and how to
write assertions.

Work incrementally: implement a test, rebuild, re-run, confirm it passes before
moving on.

---

## Step 6 — Regenerating After Source Changes

When production code changes (new subprograms, renamed parameters, changed
profiles), re-run gnattest:

```bash
gnattest -P myproject.gpr --tests-root=../../tests
```

Use the same `--tests-root` value you used at first generation —
switching layouts mid-campaign leaves orphaned files from the old layout.

GNATtest preserves existing test bodies as long as the comment markers are
intact and the subprogram's name, full expanded Ada name, and parameter order
are unchanged. New subprograms get fresh skeletons; removed subprograms leave
orphaned files (safe to delete manually).

---

## Version Control Rules

**Commit these files** (under `--tests-root=../../tests`, they live
under `<project>/tests/`):

| Path pattern | Reason |
|---|---|
| `*-test_data.adb` | Your Set_Up / Tear_Down implementations |
| `*-test_data-tests.adb` | Your test routine bodies |
| Stub bodies (`*-stub.adb`) | Your customised stub bodies (when using `--stub`) |
| Stub-data bodies (`*-stub_data.adb`) | Your setter calls in tests (when using `--stub`) |
| `test_drivers.list` | Can be committed but is safe to regenerate |

**Do NOT commit these files (add to `.gitignore`):**

| Path pattern | Reason |
|---|---|
| `*-test_data-tests.ads` | Regenerated test specs |
| `*-test_data.ads` | Regenerated test data specs |
| `<obj>/` (already typical) | Contains the entire harness; auto-generated and regenerated each run |

**Note on `gnattest_common.gpr`:** under the recommended
`--tests-root=../../tests` layout the harness — including
`gnattest_common.gpr` — lives under `<obj>/`, so it gets re-created
from defaults whenever you `gprclean`. If you have customisations you
need to preserve, see [project-setup.md](project-setup.md) for the
options.

**Tip:** Use `--omit-sloc` at generation time to suppress source-location
comments in skeleton bodies, which reduces spurious diffs when line numbers
change.

---

## Iterative Campaign Checklist

```
[ ] AUnit available (alr with aunit or GPR_PROJECT_PATH)
[ ] gnattest run; no compilation errors reported
[ ] gprbuild -P harness/test_driver.gpr succeeds
[ ] test_runner runs; all tests listed (even if unimplemented)
[ ] VCS .gitignore updated
[ ] gnattest_common.gpr committed
[ ] Test bodies implemented incrementally; each passes before moving on
[ ] gnattest re-run after any production source changes
```
