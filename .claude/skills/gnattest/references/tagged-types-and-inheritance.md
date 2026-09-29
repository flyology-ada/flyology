# GNATtest: Tagged Types and Inheritance Testing

## Overview

When a package contains a tagged type, gnattest generates test packages that
mirror the tagged type hierarchy. This enables automatic inheritance of test
routines and, optionally, Liskov Substitution Principle (LSP) validation.

---

## Test Type Hierarchy

For tagged type `T` in package `P`:
- Test routines for primitives of `T` go into `P.T_Test_Data.T_Tests`.
- `T_Test_Data.T_Tests` derives from `AUnit.Test_Fixtures.Test_Fixture`.

For a derived type `S` in package `Q` that extends `P.T`:
- `Q.S_Test_Data.S_Tests` derives from `P.T_Test_Data.T_Tests` (not from
  `Test_Fixture` directly).

This mirrors the production type hierarchy, which enables test inheritance.

---

## Set_Up for Tagged Types

The generated `Set_Up` in `*_test_data.adb` for a tagged type assigns an
allocated instance to `Gnattest_T.Fixture`:

```ada
procedure Set_Up (Gnattest_T : in out Test_T) is
begin
   Gnattest_T.Fixture := new P.T;
end Set_Up;
```

If the type has **discriminants**, gnattest generates a comment template:

```ada
procedure Set_Up (Gnattest_T : in out Test_T) is
begin
   --  Gnattest_T.Fixture := new P.T (Discriminant => <value>);
   --  Provide a value for each discriminant before enabling this line.
   null;
end Set_Up;
```

You must fill in the discriminant values — gnattest cannot infer them.

---

## Inherited Tests

By default (`--inheritance-check`), when a test suite for a derived type `S` is
run, it also executes the inherited test routines from `T_Tests` against objects
of type `S`.

Example: if `T` has `Test_Speed` and `S` inherits it without override, the
runner executes `Test_Speed` with a `S` fixture automatically.

To disable: use `--no-inheritance-check` at generation time.

---

## LSP Substitutability Validation (`--validate-type-extensions`)

This feature goes one step further than inheritance: it also runs **overridden**
parent tests against objects of the derived type.

```bash
gnattest -P myproject.gpr --tests-root=../../tests --validate-type-extensions
```

Use case: you override `Adjust_Speed` in `S` but the parent's `Test_Adjust_Speed`
encodes an invariant (e.g., speed never decreases). Running the parent test
against `S` objects reveals substitutability violations that would otherwise
only surface at runtime through dispatching calls.

**When to use:**
- When subtypes override primitives and the base class has meaningful tests.
- When performing a formal or systematic LSP audit of a type hierarchy.
- When a tagged type hierarchy is safety-critical and dispatch correctness must
  be verified.

**When to skip:**
- Overrides are intentional behavioural changes (not LSP violations, but
  documented extensions). The test failures will be expected; suppress with
  `--no-inheritance-check` on the specific subpackage, or leave them
  as known failures with explanatory comments.

---

## Summary of Switches

| Switch | Effect |
|--------|--------|
| `--inheritance-check` | Run inherited tests for derived types (default) |
| `--no-inheritance-check` | Skip inherited test execution |
| `--validate-type-extensions` | Also run overridden parent tests against derived-type objects (LSP check) |
