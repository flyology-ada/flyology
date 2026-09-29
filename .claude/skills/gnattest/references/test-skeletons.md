# GNATtest Test Skeletons

## Generated File Structure

For a package `My_Unit` with a visible subprogram `Compute`, gnattest generates:

| File | Content | Editable? |
|------|---------|-----------|
| `my_unit-test_data.ads` | Test data type declaration | No — regenerated |
| `my_unit-test_data.adb` | `Set_Up` and `Tear_Down` bodies | **Yes — yours** |
| `my_unit-test_data-tests.ads` | Test routine declarations | No — regenerated |
| `my_unit-test_data-tests.adb` | Test routine bodies (skeletons) | **Yes — yours** |

The test routine for `Compute` is named `Test_Compute_<hash>`, where `<hash>`
is a signature encoding used to distinguish overloaded subprograms.

---

## Anatomy of a Skeleton Body

```ada
--  begin read only
procedure Test_Compute_1a2b3c
  (Gnattest_T : in out Test_My_Unit);
procedure Test_Compute_1a2b3c_Setup
  (Gnattest_T : in out Test_My_Unit) renames Set_Up;
--  end read only

--  begin read only
procedure Test_Compute_1a2b3c
  (Gnattest_T : in out Test_My_Unit) is
   --  my_unit.ads:15:4: Compute
--  end read only

   use AUnit.Assertions;
begin

   Assert (False, "Test not implemented.");

--  begin read only
end Test_Compute_1a2b3c;
--  end read only
```

**The `--  begin read only` / `--  end read only` comment blocks are
non-negotiable.** GNATtest uses them to locate your code during regeneration.
Remove them and your test body will be silently replaced by a fresh "not
implemented" stub on the next run.

Replace the `Assert (False, "Test not implemented.");` statement with your
actual test code. Do not touch anything outside the unprotected region between
the two inner comment blocks.

---

## Writing Assertions

Import `AUnit.Assertions` (already done in the skeleton) and call `Assert`:

```ada
use AUnit.Assertions;

-- Boolean check with a message
Assert (My_Unit.Compute (2) = 4, "Compute(2) should return 4");

-- Negated check
Assert (My_Unit.Compute (0) /= 0, "Compute(0) should not return 0");
```

`Assert` raises `AUnit.Assertions.Assertion_Error` on failure, which the
harness catches and records. Do not use `pragma Assert` — it raises
`Assertion_Error` from a different package and may be disabled by compiler
switches.

For tests with multiple checks, give each its own descriptive message so
failures are easy to locate:

```ada
Assert (Result.X = 1, "X component wrong");
Assert (Result.Y = 2, "Y component wrong");
```

---

## Set_Up and Tear_Down

`my_unit-test_data.adb` contains `Set_Up` and `Tear_Down`:

```ada
procedure Set_Up (Gnattest_T : in out Test_My_Unit) is
begin
   --  Initialise shared state here.
   --  Gnattest_T.Fixture is a pointer to the type under test (for tagged types).
   null;
end Set_Up;

procedure Tear_Down (Gnattest_T : in out Test_My_Unit) is
begin
   --  Release resources allocated in Set_Up.
   null;
end Tear_Down;
```

`Set_Up` runs before every test routine in the package; `Tear_Down` runs after.
Add components to `Test_My_Unit` in `my_unit-test_data.ads` to share state
across `Set_Up` and test routines — but note that `my_unit-test_data.ads` is
regenerated, so add them in the `-- start read only` / `-- end read only` gap
if one exists, or leave a note to add them after each regeneration.

For tagged type testing, `Set_Up` sets `Gnattest_T.Fixture` to an allocated
instance of the type under test. If the type has discriminants, gnattest
generates a comment template; you must fill in the discriminant values.

---

## Skeleton Preservation Rules

GNATtest preserves an existing test body when ALL of the following hold:

1. The subprogram's **simple name** is unchanged.
2. The subprogram's **full expanded Ada name** (package hierarchy) is unchanged.
3. The **order of parameters** is unchanged.
4. The `--  begin read only` / `--  end read only` **comment markers are intact**.

If any of these change, gnattest generates a new skeleton alongside the old
file. The old file is not deleted — you must manually migrate your test code
and delete the stale file.

**Renaming a subprogram** therefore requires:
1. Running gnattest to generate the new skeleton.
2. Manually copying your test body into the new skeleton.
3. Deleting the old skeleton file.

---

## Useful Generation Options

| Option | Effect on skeletons |
|--------|-------------------|
| `--skeleton-default=pass` | Unimplemented tests pass instead of fail |
| `--omit-sloc` | Removes the `--  my_unit.ads:NN:MM` comment from skeletons; reduces VCS noise |
| `--test-case-only` | Only generates skeletons for subprograms with a `Test_Case` pragma or aspect |
| `--test-duration` | Adds timing output per test to the runner |
