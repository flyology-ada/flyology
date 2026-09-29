# Library Projects with Restricted `Library_Interface`

GNATtest's auto-generated harness lives in **its own GPR**
(`<obj>/gnattest/harness/test_driver.gpr`), which makes it an *external
client* of the project under test. When that project is a library project
with `Library_Interface` set, external clients are restricted to the units
listed there — and the harness needs to import every unit it tests, most of
which are not in the interface. The result is a build failure that is not
obvious from the gnattest skill's default workflow.

This document is the recipe for that case.

---

## Decision tree — do I need this file?

Answer in order; stop at the first "no" — you can skip the rest of this
file.

1. **Is your project a library project?** Look in your `.gpr` for
   `for Library_Name use ...` (and usually also `for Library_Dir use ...`).
   No → not a library project; the default skill workflow applies.
2. **Is `Library_Interface` set?** Look for `for Library_Interface use (...)`.
   No → external clients can import any unit; the harness will compile fine.
3. **Does `Library_Interface` cover every unit you want to test?** If
   `Library_Interface use ("A", "B", "C")` and you only ever want gnattest
   to test `A`, `B`, and `C`, you can pass those source files explicitly
   on the gnattest command line and the default workflow still applies.

If you reached here, your project hits the structural problem below.
Use the **sibling test-only GPR** recipe.

---

## The error you'll see

After running gnattest against your library project (any output mode —
`--tests-root`, `--tests-dir`, or `--subdirs`) and then trying to build
the generated harness, gprbuild fails with:

```
Unit "gnattest_main_suite" cannot import unit "<your.unit>":
  it is not part of the interfaces of its project "<Library_Name>"
```

(One line per non-interface unit the harness tries to with.) Grep for
`not part of the interfaces` in your build log to confirm.

### Why this happens

GNATtest emits `<obj>/gnattest/harness/test_driver.gpr` as a separate
project, and the harness's top package (`gnattest_main_suite.adb`) `with`s
every test_data package, which transitively `with`s every unit under test.
Because `test_driver.gpr` does not extend the production GPR, it is treated
as an external client, and Ada's library-project rules forbid external
clients from importing non-interface units. Loosening
`Library_Interface` on the production GPR is usually undesirable: it is
load-bearing for whatever consumer the library was built for (a C/Rust
binding, a separately-built executable, etc.).

---

## Recipe — sibling test-only GPR

Create a second `.gpr` file beside your production GPR, mirroring its
`Source_Dirs` but **omitting** `Library_Interface` and every other
`Library_*` attribute. The sibling GPR is a standard project (not a library
project), so the harness can import any unit transitively reachable from
its source dirs.

### Skeleton

```ada
--  Test-only sibling of <production>.gpr.
--
--  Mirrors the Source_Dirs of <production>.gpr so the gnattest harness can
--  reach internal units which are NOT exposed by the production library
--  project's Library_Interface. Add any extra source dirs (test stubs,
--  helpers) here.

project <Production>_Test is

   for Source_Dirs use
     ("<same dirs as production>",
      "test_stubs/");           --  if you need FFI stubs; see below

   for Object_Dir use "obj/test/<your-build-profile>";
   for Create_Missing_Dirs use "True";

   --  No Library_Name, Library_Dir, Library_Kind, Library_Interface, etc.

   package Compiler is
      for Default_Switches ("Ada") use ("-g", "-gnat2022");
      --  Note: switches set here apply to the *units under test* compiled
      --  via this GPR. The harness build (test_driver.gpr) is a separate
      --  GPR that ignores this; for harness-side switches see
      --  workflow.md § Step 3 — ada version override.
   end Compiler;

   package Binder is
      for Switches ("Ada") use ("-Es");  --  Symbolic traceback
   end Binder;

end <Production>_Test;
```

### What to mirror, what not to mirror

| Production GPR attribute | In sibling test GPR? |
|---|---|
| `Source_Dirs` | **Yes** — copy verbatim. |
| `Object_Dir` | **No** — give the test GPR its own (e.g. `obj/test/...`) so test artefacts don't collide with production. |
| `Library_Name` / `Library_Dir` / `Library_Kind` | **No** — leave out entirely; the test GPR is a standard project. |
| `Library_Interface` / `Library_Standalone` / `Library_Auto_Init` / other `Library_*` | **No** — these are what you're escaping. |
| `Languages` | Mirror, then **add** any test-side language (e.g. `"C"` for FFI stubs). |
| `package Compiler` switches | Mirror or replace as appropriate for tests. Keep `-gnatXXXX` consistent with the production GPR. |
| `package Binder` switches | Usually mirror. |
| `package Linker` | Mirror only if your tests actually need to link against the same external libs. Often you can drop them. |
| `package Install` | **No** — tests are not installed. |

### Then run gnattest against the sibling GPR

```bash
gnattest -P <production>_test.gpr --tests-root=../../tests --no-subprojects
```

Or, under Alire (see [SKILL.md § Locating GNATtest](../SKILL.md#locating-gnattest)):

```bash
PATH="$HOME/.alire/bin:$PATH" alr exec -- \
  gnattest -P <production>_test.gpr --tests-root=../../tests --no-subprojects
```

The `../../` count is the depth of the test GPR's `Object_Dir` — adjust
to match yours; see
[project-setup.md § Path resolution](project-setup.md#path-resolution-applies-to-a-and-b).
`--no-subprojects` is recommended for Alire-managed crates — without it,
gnattest crawls the full dependency closure (gnatcoll, xmlada, …) and
emits thousands of harness files instead of tens.

The harness is then built and run as in
[workflow.md § Steps 3–4](workflow.md#step-3--build-the-test-driver), with
the Ada-version caveat described in
[workflow.md § Step 3](workflow.md#step-3--build-the-test-driver).

---

## Pairing with a nested test crate (Alire)

If you're following the `/alire` skill's nested-test-crate convention to
keep test dependencies (AUnit, mocks, etc.) off the production crate's
manifest, place the sibling test GPR **inside the nested test crate**
rather than beside the production GPR. Everything test-related — the test
GPR, FFI stubs, generated skeleton bodies — then lives under
`<parent>/tests/`, and the production crate's `alire.toml` stays clean.

### Layout

```text
<parent_crate>/
├── alire.toml                   # production crate; no test deps
├── <production>.gpr             # production library project
├── src/
└── tests/                       # nested test crate
    ├── alire.toml               # has aunit + path-pin to ..
    ├── tests.gpr                # alr-generated; leave alone
    ├── <production>_test.gpr    # ← sibling test GPR LIVES HERE
    ├── test_stubs/              # ← FFI no-op stubs LIVE HERE
    │   └── test_stubs.c
    └── tests/                   # ← gnattest skeleton bodies LAND HERE
        └── ...
```

### Test GPR placement and `Source_Dirs`

The test GPR's `Source_Dirs` are interpreted relative to the test GPR's
own location. From `<parent>/tests/`, the production sources are two
levels up:

```ada
project <Production>_Test is
   for Languages   use ("Ada", "C");
   for Source_Dirs use
     ("../../src/",            --  parent crate's src/
      "../../src/<subdirs>/",  --  any other production source dirs
      "test_stubs/");          --  inside nested crate
   for Object_Dir use "obj/test/development";
   for Create_Missing_Dirs use "True";

   package Compiler is
      for Default_Switches ("Ada") use ("-g", "-gnat2022");
      for Default_Switches ("C")   use ("-g");
   end Compiler;
end <Production>_Test;
```

The test GPR must remain **self-contained** — do not `with` the alr-
generated `tests_config.gpr`, and do not `with` the production GPR.
`tests_config.gpr` transitively imports the production project (via the
path-pin `alr` adds), and a `with` of either one would cause the
production sources to be loaded by both `tests.gpr` (via the path-pin)
and `<production>_test.gpr` (via the `with`), triggering
`unit "<X>" cannot belong to several projects`. Keeping the test GPR's
`with` clauses to zero (or to test-only helpers) sidesteps this.

### Alire setup

From the parent crate's root:

```bash
alr -n init --bin tests
cd tests
alr -n with <parent_crate_name> --use=..
alr -n with aunit
```

Then drop or comment out `for Main use ("tests.adb");` and
`for Exec_Dir use "bin";` in the alr-generated `tests.gpr`. You don't
need them — the gnattest harness produces its own `test_runner`. Leaving
them in causes `alr build` to create `tests/bin/tests` (a file), and
gnattest can collide with that path; see
[project-setup.md § Alire Nested Test Crates](project-setup.md#alire-nested-test-crates)
for the full discussion.

### Skeleton output location

The skill's canonical layout is `--tests-root=<n>/tests` landing bodies
at `<test_GPR_directory>/tests/`. Here the test GPR is at
`<parent>/tests/<production>_test.gpr`, so the destination is
`<parent>/tests/tests/`.

For `Object_Dir = "obj/test/development"` (3 levels deep):

```bash
alr exec -- gnattest -P <production>_test.gpr --no-subprojects \
  --tests-root=../../../tests
```

Result: skeleton bodies appear at
`<parent>/tests/tests/<mirror of source dirs>/<unit>-test_data-tests.adb`,
all inside the nested crate. (The `tests/tests/` doubling is real but
unavoidable: the outer `tests/` is the nested *crate*; the inner
`tests/` is the gnattest output directory inside it. Calling the
output dir anything other than `tests` would break consistency with
the rest of the skill.)

The `../../../` count escapes the 3-level `Object_Dir`. If you change
`Object_Dir`, adjust the `../` count accordingly — see
[project-setup.md § Path resolution](project-setup.md#path-resolution-applies-to-a-and-b).

If you'd rather have a flat layout, swap `--tests-root` for
`--tests-dir=../../../tests` — all skeleton bodies land directly in
`<parent>/tests/tests/`, no inner source-dir mirror.

### Build and run

```bash
# From inside <parent>/tests/
alr exec -- gprbuild \
  -P obj/test/development/gnattest/harness/test_driver.gpr \
  -cargs:Ada -gnat2022
./obj/test/development/gnattest/harness/test_runner
```

(`-cargs:Ada -gnat2022` is the Ada-version override —
see [workflow.md § Step 3](workflow.md#step-3--build-the-test-driver).)

### Why not extend the production GPR?

Project extension (`project <Production>_Test extends "<production>.gpr"`)
sounds attractive: the extending project inherits `Source_Dirs` and
compiler settings dynamically, so changes to the production GPR
propagate to the test build automatically. It also lets you override
`Library_Interface` to a wide list, opening the harness path.

The catch is that **the extending GPR must live in the same directory
as the extended GPR**. `Mars_Rover'Source_Dirs` (or equivalent) returns
the *raw* relative paths from the production GPR — when those paths are
re-evaluated against the extending project's directory, they only
resolve correctly if both GPRs share a directory. From inside
`tests/`, an inherited `"../src/"` resolves to `tests/../src/` =
`<parent>/src/` — which exists by accident only if you're one level
deep, not two.

So extension forces the test GPR (and any test-only resources like
FFI stubs added to its `Source_Dirs`) to live beside the production
GPR — outside the nested test crate. If you accept that placement
and value the dynamism, extension is viable; otherwise stick with the
self-contained sibling shown above.

---

## FFI / external symbols at the link step

If your production library is the Ada side of a binding to native code
(C/C++/Rust, etc.) — e.g. `pragma Import (C, ...)` declarations referring
to functions provided by the foreign side — those symbols are not present
in a unit-test build. The harness link step will fail with
`undefined reference to <symbol>`.

Provide a single C file with no-op definitions of just the symbols the
harness pulls in transitively, and add it to the sibling GPR's
`Source_Dirs`:

```c
/*
 * Test-only no-op stubs for the FFI symbols imported by <binding>.adb.
 * Tests that exercise those code paths should provide their own behaviour
 * or use a stubbing framework.
 */
#include <stdint.h>

uint64_t my_lib_clock(void) { return 0; }
void     my_lib_set_state(int32_t s) { (void) s; }
/*  …one no-op per imported symbol… */
```

Then in the sibling GPR:

```ada
for Languages   use ("Ada", "C");
for Source_Dirs use (..., "test_stubs/");
```

If a new `pragma Import` is later added to the binding, add a matching
no-op stub.

---

## Why not the alternatives?

| Alternative | Why it's worse for this case |
|---|---|
| **Add the missing units to `Library_Interface`** in the production GPR. | Defeats the purpose of `Library_Interface`. The interface is part of the library's contract with its consumers; widening it means the library now exports symbols its real consumers don't need. If the library is delivered as a standalone shared object, the symbol table grows; if it's used to enforce Ada encapsulation, that encapsulation is broken. Avoid. |
| **Drop `Library_Interface` entirely** from the production GPR. | Same as above, plus you lose the standalone-library guarantee that initialization runs correctly. Don't do this just for tests. |
| **Modify the alr-generated `tests.gpr`** to source parent files directly (`for Source_Dirs use ("../src/", ...);`) instead of adding a separate sibling GPR. | The alr-managed `tests.gpr` is loaded through the path-pin to the parent crate, which means alr also loads the parent's `mars_rover.gpr` into the same project closure. With both GPRs claiming `../src/<unit>.ads`, you get `unit "<X>" cannot belong to several projects`. Dropping the path-pin avoids the collision but leaves you maintaining the parent's source-dir list by hand inside the test crate's `tests.gpr` — and `tests.gpr` is also alr-rewritten on `alr with`/`alr update`, so your edits are unstable. The recipe above sidesteps both problems by using a *separate* test GPR (`<production>_test.gpr`) that doesn't `with` `tests_config.gpr`. |

The sibling-GPR pattern is the cleanest because the production GPR is
untouched, the test GPR is self-contained, and everything else in this
skill (`--tests-root`, `gnattest_common.gpr`, the `.gitignore` rules)
keeps working unchanged. For the trade-off between placing the test GPR
beside the production GPR vs. inside a nested test crate (and the
`extends` option, which forces sibling placement), see the recipe and
the [Pairing with a nested test crate](#pairing-with-a-nested-test-crate-alire)
section above.

---

## Cross-references

- [project-setup.md § Library projects](project-setup.md#library-projects) — directory layout for the sibling GPR.
- [project-setup.md § Alire Nested Test Crates](project-setup.md#alire-nested-test-crates) — `tests.gpr` Main/Exec_Dir caveat that applies when pairing with a nested test crate.
- [workflow.md § Step 1](workflow.md#step-1--initial-skeleton-generation) — when to reach for this file.
- [workflow.md § Step 3](workflow.md#step-3--build-the-test-driver) — Ada-version override pattern (relevant if your production GPR uses `-gnat2022` or newer).
- `/alire` skill, `testing.md` — nested-test-crate convention this section pairs with.
