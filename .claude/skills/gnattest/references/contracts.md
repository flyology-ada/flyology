# GNATtest: Testing with Contracts

## Overview

GNATtest recognises `Pre`, `Post`, and `Test_Case` pragmas and aspects (Ada
2012+). When `Test_Case` is present, gnattest generates **one test routine per
test case** rather than a single routine per subprogram, and wraps the call with
the composed Pre/Post from both the subprogram contract and the test case.

---

## Test_Case Basics

```ada
function Sqrt (X : Float) return Float
  with
    Pre  => X >= 0.0,
    Post => Sqrt'Result >= 0.0,
    Test_Case => (Name => "Normal input",   Mode => Nominal),
    Test_Case => (Name => "Negative input", Mode => Robustness);
```

Or with pragmas:

```ada
pragma Test_Case (Name => "Normal input",   Mode => Nominal);
pragma Test_Case (Name => "Negative input", Mode => Robustness);
```

---

## Nominal vs. Robustness Mode

| Mode | Precondition | Postcondition |
|------|-------------|---------------|
| `Nominal` | **Composed** with subprogram `Pre` (test input must satisfy both) | **Composed** with subprogram `Post` |
| `Robustness` | Test case `Requires` **only** (subprogram `Pre` is intentionally bypassed) | Test case `Ensures` **only** |

**Nominal** tests verify the subprogram works correctly for valid inputs.
**Robustness** tests verify how the subprogram responds to inputs that violate
its precondition (error paths, range checks, etc.).

### Generated Wrapper Behaviour

For Nominal mode, the harness wraps the call so that a precondition violation
is reported as a test failure (not a program exception). Inputs that satisfy
the test case's `Requires` but violate the subprogram's `Pre` will cause the
test to fail with a precondition-violation diagnosis.

For Robustness mode, the subprogram's `Pre` is not checked, so inputs that
would normally violate it are allowed through to the body.

---

## Example: Writing a Nominal Test Case

Given the `Sqrt` example above, the skeleton for "Normal input" looks like:

```ada
procedure Test_Sqrt_Normal_Input_... is
   use AUnit.Assertions;
begin
   Assert (False, "Test not implemented.");
end Test_Sqrt_Normal_Input_...;
```

Replace with a call that is within both `Pre` and the test case `Requires`:

```ada
Assert (abs (Sqrt (9.0) - 3.0) < 0.001, "sqrt(9) should be ~3");
Assert (abs (Sqrt (4.0) - 2.0) < 0.001, "sqrt(4) should be ~2");
```

Passing `25.0` would still be fine. Passing `-1.0` (below `Pre`) would cause the
test to fail at the wrapper's precondition check — which is the intended
behaviour for a Nominal test.

---

## Example: Writing a Robustness Test Case

For the "Negative input" case in Robustness mode, the subprogram `Pre` is
bypassed. Test the error-handling behaviour directly:

```ada
Assert (Sqrt (-5.0) = -1.0, "negative input should return sentinel -1.0");
```

If `Sqrt` raises an exception instead of returning a sentinel, the test will
fail with an unexpected exception. Handle this with a `begin ... exception`
block if the contract documents that an exception is the intended response.

---

## `--test-case-only`

When passed at generation time, gnattest only generates skeletons for
subprograms that have at least one `Test_Case` pragma or aspect. Subprograms
without `Test_Case` are silently skipped.

Use this to focus a testing campaign on the formally specified subset of an API,
and add `Test_Case` incrementally as coverage increases.

---

## Pre/Post Without Test_Case

Subprograms with only `Pre` and `Post` (no `Test_Case`) get a single skeleton
per subprogram, the same as an unconstrained subprogram. The contracts are not
automatically checked by the test framework — you must write assertions that
exercise both normal and boundary cases manually.

To get per-contract test routines with wrapper checking, add `Test_Case`
aspects.
