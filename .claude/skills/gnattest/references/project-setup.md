# GNATtest Project Setup and Directory Layout

## Choosing a Directory Layout

GNATtest offers three mutually exclusive output modes for test skeletons.
Choose before the first run — changing modes later leaves orphaned
skeleton files from the old layout.

**Recommended default: `--tests-root=<n>/tests` — mirrored hierarchy
under a top-level `tests/` directory beside `src/`.**

The `<n>` is the right number of `../`s to escape your `Object_Dir`. See
**Path resolution** below for the formula. The destination is
`<project_root>/tests/` regardless of `Object_Dir` depth — that's the
canonical layout this skill recommends.

### Option A: `--tests-root=rootdir` (mirrored hierarchy) — **recommended**

Recreates the source directory hierarchy under `rootdir`.

```
src/
  subsystem/
    pkg_a.ads
tests/                      ← lives beside src/, at the project root
  subsystem/
    pkg_a-test_data-tests.adb
```

Best for: most projects. Familiar layout (top-level `tests/` sibling to
`src/`), one place to find all test bodies, and the mirror preserves the
source-tree structure for navigation.

### Option B: `--tests-dir=dir` (flat, centralised)

All test packages land in one directory regardless of source structure.

```
tests/                      ← lives beside src/
  pkg_a-test_data-tests.adb
  pkg_b-test_data-tests.adb
```

Best for: small projects with few packages where you'd rather see a
single flat list than a mirrored hierarchy.

### Option C: `--subdirs=dirname` (co-located with sources)

Test packages are placed in a subdirectory named `dirname` next to each
source file's directory.

```
src/
  pkg_a.ads
  pkg_a.adb
  tests/                    ← tests alongside sources
    pkg_a-test_data-tests.adb
```

Best for: teams who want tests physically close to the code they test,
or projects where `--tests-root` would have to climb across crate
boundaries.

### Path resolution (applies to A and B)

Relative paths given to `--tests-root` and `--tests-dir` are resolved
against the **`Object_Dir`** (not the CWD, not the GPR's directory).
Passing `--tests-root=tests` therefore lands bodies at
`<obj>/tests/` — still under `obj/` and gitignored. To escape `obj/`,
prepend one `../` per level of `Object_Dir`:

| `Object_Dir` setting | Recommended path |
|---|---|
| `obj/` (1 level) | `--tests-root=../tests` |
| `obj/development/` (2 levels — Alire default) | `--tests-root=../../tests` |
| `obj/test/development/` (3 levels) | `--tests-root=../../../tests` |

The destination is always `<test_GPR_directory>/tests/`. (`--subdirs`
resolves relative to each `Source_Dir` instead, so it has no `../`
math — but it can't centralise tests under one root.)

**If no output mode is specified**, tests go to `gnattest/tests/` under
the object directory (equivalent to `--tests-dir=gnattest/tests`).
**Avoid this default** — `obj/` is almost always gitignored, so the
skeleton bodies you write will not be tracked by git, and `gprclean`
will delete them along with build artefacts.

---

## Harness Directory

`--harness-dir=dir` controls where the harness packages and `test_driver.gpr`
are placed. Relative paths are resolved from the project's object directory,
so `--harness-dir=tests/harness` puts the harness at `<obj>/tests/harness/`
— still under `obj/`.

**For most projects, leave `--harness-dir` unset.** The harness then lives
under `<obj>/gnattest/harness/`, is fully regenerated on every run, and is
gitignored along with the rest of the build tree. This is fine — every file
in the harness directory except `gnattest_common.gpr` is regenerated from
sources, and `gnattest_common.gpr` is recreated from defaults if absent.

If you have persistent customisations to `gnattest_common.gpr` (extra
compiler flags, extra source dirs for test helpers), you have three
options:

1. **Put the settings in your main project file's `Compiler` package**
   instead — these inherit through the harness build automatically. Cleanest
   if you do not need test-only switches.
2. **Keep a checked-in copy** of `gnattest_common.gpr` somewhere else and
   `cp` it into `<obj>/gnattest/harness/` after each `gprclean`.
3. **Use `--harness-dir=<absolute-path>`** to put the harness outside `obj/`
   so it survives `gprclean`. Note the worktree/portability cost of absolute
   paths.

---

## GPR Package `Gnattest`

Place `gnattest` options in the project file to avoid repeating them on the
command line. All attributes can be overridden by command-line switches.

```ada
package Gnattest is
   --  Recommended: --tests-root with a path that escapes Object_Dir.
   --  Adjust the ../ count to match your Object_Dir depth.
   for Tests_Root  use "../../tests";          --  Object_Dir depth = 2 (Alire default)
   -- for Tests_Dir   use "../../tests";       --  alternative: flat layout
   -- for Subdir      use "tests";             --  alternative: beside each Source_Dir
   --  Harness_Dir is best left unset — see the Harness Directory section above.

   for Stubs_Dir    use "tests/stubs";    -- used with --stub
   for Skeletons_Default use "fail";      -- "pass" | "fail"

   for Additional_Tests use "extra/harness.gpr";

   for Default_Stub_Exclusion_List use "no_stub.txt";
   for Stub_Exclusion_List ("runtime_pkg.ads") use "no_stub_runtime.txt";

   --  Pass any other switches here:
   for Gnattest_Switches use
     ("--omit-sloc",
      "--exit-status=on",
      "--test-duration");
end Gnattest;
```

---

## Customising the Harness Build

`gnattest_common.gpr` is created once and never overwritten. Use it to:

- Add compiler flags needed to compile your tests (e.g., debug info):
  ```ada
  package Compiler is
     for Default_Switches ("Ada") use ("-g");
  end Compiler;
  ```
- Add extra source directories (e.g., test helpers, shared fixtures):
  ```ada
  for Source_Dirs use Source_Dirs & ("../test_helpers");
  ```
- Add linker options for test-only libraries.

**Caveat — Ada language version.** `gnattest_common.gpr` is **not** the
right place to set `-gnat2022` (or any other `-gnatXXXX`). The auto-
generated `test_driver.gpr` extends `Gnattest_Common.Compiler` and appends
`-gnat2012` after your switches; on last-flag-wins, the gnattest-side
`-gnat2012` overrides whatever you put here. Pass `-cargs:Ada -gnat2022`
on the gprbuild command line instead. See
[workflow.md § Step 3](workflow.md#step-3--build-the-test-driver) for the
full pattern.

---

## Library Projects

If the project under test is a **library project** (`for Library_Name use
...`) with `for Library_Interface use (...)` set, and that interface does
not cover every unit you want gnattest to test, the harness build will
fail with `Unit ... cannot import unit ... it is not part of the
interfaces of its project ...`. The harness lives in its own GPR, which
makes it an external client of the library, and external clients are
restricted to interface units.

The fix is a **sibling test-only GPR** that mirrors the production GPR's
`Source_Dirs` but omits `Library_Interface` and the other `Library_*`
attributes. Point gnattest at the sibling GPR; production stays untouched.

See [library-projects.md](library-projects.md) for the full recipe,
including FFI-stub handling and a comparison with alternatives.

---

## Alire Nested Test Crates

The Alire convention (see the `/alire` skill's `testing.md`) is to put
tests in a **nested test crate** created with `alr -n init --bin tests`,
which produces a `tests/` subdirectory containing its own `tests.gpr`.
That `tests.gpr` is the alr-managed crate GPR; it is not the file
gnattest runs against. For library projects, the test GPR gnattest
processes is a separate file you create. See
[library-projects.md § Pairing with a nested test crate](library-projects.md#pairing-with-a-nested-test-crate-alire)
for the full recipe.

`alr -n init --bin tests` writes two attributes you should remove from
the alr-generated `tests.gpr` whenever you're using the gnattest harness
(`test_runner`) as your test executable — the normal case for any
gnattest-driven project:

```ada
package Tests is
   for Main use ("tests.adb");
   for Exec_Dir use "bin";       --  bin/ relative to tests/
end Tests;
```

The nested crate doesn't need its own executable; the gnattest harness
build produces one. Replace the auto-generated `package Tests is ... end
Tests;` with nothing, or remove just those two attributes.

Two failure modes if you leave them in:

- `alr build` from inside `tests/` will try to compile `tests/src/tests.adb`
  (the empty stub `alr init` left behind) and link it into
  `tests/bin/tests`. That works but produces a useless executable; if
  you later add `with`s in `tests.adb` for experimentation it can break
  the build in confusing ways.
- If you pick `--subdirs=tests` as your gnattest output mode, gnattest
  tries to `mkdir tests/bin/tests/` (a `tests/` subdir under each source
  dir), but `tests/bin/tests` is already a *file* (the `alr build`
  executable). Use `--tests-root` or `--tests-dir` instead, or use a
  different `--subdirs` name (e.g. `--subdirs=t`).

> Coordination with the `/alire` skill: `alr init --bin` is currently
> the only path to a nested test crate; if Alire grows an `alr init
> --test` flavor that omits `Main`/`Exec_Dir`, prefer that.

---

## Aggregate Projects

When `-P` points to an aggregate project, gnattest processes each aggregated
project **sequentially and independently**, producing one harness per project in
that project's object directory.

No top-level makefile or project file is generated to build all harnesses
together — you must create that yourself.

**Shared dependencies in aggregate projects:** if two aggregated projects share
a common dependency, use relative paths with `--subdirs` or `--stubs-dir` so
that tests for the shared package land in the same location and are not
duplicated. Using `--harness-dir` or `--tests-dir` with an **absolute** path
causes later aggregated projects to overwrite output from earlier ones.

---

## VCS `.gitignore` Template

For the recommended `--tests-root=../../tests` layout — harness lives in
`<obj>/` (already gitignored) and skeleton bodies live under
`<project>/tests/`:

```
# GNATtest — regenerated specs (rewritten on every gnattest run)
tests/**/*-test_data.ads
tests/**/*-test_data-tests.ads

# Keep these (do NOT add to .gitignore):
# tests/**/*-test_data.adb           ← your Set_Up/Tear_Down
# tests/**/*-test_data-tests.adb     ← your test bodies
```

If you instead use `--harness-dir=<absolute>` to put the harness outside
`obj/`, additionally exclude the auto-generated harness pieces:

```
<harness-path>/test_driver.gpr
<harness-path>/suite_*
<harness-path>/test_runner*
<harness-path>/*.ali
<harness-path>/*.o
# Keep <harness-path>/gnattest_common.gpr if you have customised it.
```
