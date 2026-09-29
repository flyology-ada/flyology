# Ghost Code, Lemmas, and Axioms

## Concepts

### Ghost code is proof-only

Ghost entities (`with Ghost`) exist solely for verification. They are stripped
during normal compilation -- zero runtime cost. Ghost code can read non-ghost
state but cannot affect it.

### Hint strength ordering

Always reach for the lightest tool first:

1. **`pragma Assert`** -- a breadcrumb. If discharged, the prover uses it as
   a known fact for subsequent checks. Try this first.
2. **Ghost lemma** (`is null` or with a body) -- a provable ghost procedure.
   GNATprove verifies the postcondition, then callers get it for free.
3. **Ghost axiom** (`with Import`) -- an assumed-true postcondition that
   GNATprove does **not** verify. This is an unchecked assumption that
   threatens soundness. **Never introduce without explicit user permission.**

**An assertion is also a hypothesis.** Every discharged `pragma Assert` stays
in context and is fed to the solver for all subsequent checks in scope. Add
assertions only where a specific check needs them -- never speculatively "to
help". Surplus asserts enlarge the context and can slow or break unrelated
checks, the same failure mode as an over-large subprogram.

### Lemmas are ordinary subprograms

A lemma is just a ghost procedure. Its "lemma-ness" comes from two SPARK
properties: it is ghost (no runtime effect, erased at compile time), and
its postcondition is verified modularly (callers assume the postcondition
without re-inspecting the body). Nothing else distinguishes it from a
regular procedure.

Two consequences worth internalizing:

- **Lemmas compose.** A lemma body can call other lemmas to pick up their
  postconditions, exactly like production code calls helpers. When a
  lemma body grows unwieldy, decompose it into smaller lemmas and call
  them -- the same instinct that applies to regular subprograms applies
  here.
- **Lemma bodies are subject to normal proof rules.** Loop invariants,
  overflow checks, and every other obligation must still discharge inside
  the body. The "lemma" label grants no shortcuts.

### When a lemma doesn't prove

Nearly every "this lemma doesn't prove" moment has the same cause: the
contract is underspecified. Before suspecting solver weakness or a SPARK
modeling limitation, check:

- **Does the `Pre` carry every fact the body needs?** Parameter subtypes
  and their constraints, ranges on globals, relationships between inputs.
  If the body relies on `P (1, 1) >= 0` and the Pre doesn't say so, the
  lemma cannot prove — the solver starts from the Pre, not from "whatever
  was true at the call site". SPARK's modularity is absolute
  (see [spark.md § Modularity is absolute](spark.md)).
- **Does the `Post` expose every fact callers need?** If the body
  establishes a useful intermediate fact that callers then re-derive,
  strengthen the `Post`. The body's work does not leak out of its own
  scope.
- **Is there a frame gap?** For `in out` parameters or `Global` state,
  callers lose any pre-call facts about unmodified parts unless the
  `Post` or a frame clause says they are unchanged.

A common confusion: "the lemma didn't prove, but moving the same code
into a nested non-ghost procedure did." The nested version almost always
has a tighter effective contract — typically because concrete `in out`
parameters carry subtype bounds and its natural `Post` mentions more than
the ghost lemma's did. The principle is the same either way: whatever
the body needs or produces, the contract must state. Switching from
lemma to nested procedure does not bypass modularity; it just forces you
to write the contract a different way.

### Expression functions vs. regular ghost functions

An **expression function** generates an implicit postcondition derived from its
expression body. Callers see this postcondition automatically -- no explicit
`Post` needed:

```ada
function Is_Sorted (A : Arr) return Boolean is
  (for all I in A'First .. A'Last - 1 => A(I) <= A(I+1))
with Ghost;
-- Implicit Post: Is_Sorted'Result = (for all I in ...)
```

A **regular function**'s body is opaque at call sites. The prover only sees
the explicit postcondition. Prefer the expression function form so the prover
gets the definition for free.

**Visibility caveat**: If an expression function is *defined* in a package body
(even if *declared* in the spec), the implicit postcondition is only available
within the same unit, not to external callers. Define expression functions in
the spec to make the implicit postcondition universally available.

### Connecting runtime code to ghost specs

When a runtime helper computes the same property as a ghost expression function,
bridge them with a conditional postcondition:

```ada
function Is_Palindrome_Rt (S : String) return Boolean with
  Post => (if Is_Palindrome_Rt'Result then Is_Palindrome (S));
```

The `if ... then` form is deliberate: you only need the True-implies-ghost
direction. Proving full equivalence is harder and usually unnecessary.

### SPARK lemma library

Standard lemmas in `SPARK.Lemmas.*` provide **relational** properties
(monotonicity, ordering). Call them at the proof point:

```ada
Lemma_Div_Is_Monotonic (Val1 => X, Val2 => Y, Denom => Z);
-- Prover now knows: X <= Y implies X/Z <= Y/Z (for Z > 0)
```

These give relational facts between values, not absolute bounds on a single
value -- for bounds, constrain the inputs via `Pre` or subtypes.

| Package | Domain |
|---------|--------|
| `SPARK.Lemmas.Integer_Arithmetic` | Signed integer |
| `SPARK.Lemmas.Long_Float_Arithmetic` | Long_Float monotonicity |
| `SPARK.Lemmas.Float_Arithmetic` | Float monotonicity |
| `SPARK.Lemmas.Mod32_Arithmetic` | Modular 32-bit |

## Patterns

### Null-body lemma (try first)

```ada
procedure Lemma_Product_Bounded (A : Positive_Float; B : Unit_Float)
with Ghost, Pre => B in 0.0 .. 1.0, Post => A * B <= Positive_Float'Last;
procedure Lemma_Product_Bounded (A : Positive_Float; B : Unit_Float) is null;
```

GNATprove often proves the postcondition from parameter subtypes alone.

### Inductive / recursive lemma

```ada
procedure Lemma_Mono (I : Natural) with Ghost,
  Pre => I >= 1, Post => F(I-1) < F(I),
  Subprogram_Variant => (Decreases => I);
procedure Lemma_Mono (I : Natural) is
begin
   if I > 1 then Lemma_Mono (I - 1); end if;
end;
```

### Case-splitting lemma loop

For proving a quantifier over a multi-region array:

```ada
procedure Lemma_Is_Palindrome (R : String; ...) with Ghost,
  Post => Is_Palindrome (R);
procedure Lemma_Is_Palindrome (R : String; ...) is
begin
   for I in 0 .. R'Length / 2 - 1 loop
      pragma Loop_Invariant
        (for all J in 0 .. I-1 => R(R'First+J) = R(R'Last-J));
      if I < Boundary then
         pragma Assert (...);  -- case 1
      else
         pragma Assert (...);  -- case 2
      end if;
      pragma Assert (R(R'First+I) = R(R'Last-I));
   end loop;
end;
```

### Wrap heavy ghost code in a ghost lemma

Any complex piece of ghost code needed solely for proof carries a large
footprint of intermediate VCs. Left inline, this heavy context remains in scope
as hypotheses for every later check in the enclosing subprogram—causing
unrelated properties to time out. Furthermore, the compiler will not
automatically optimize away or remove complex statements (like loops or
conditionals) just because they only have ghost effects.

Move the ghost code into a dedicated ghost lemma. Its Post should export only
the exact fact the caller needs; the heavy context stays inside the lemma body
and never pollutes the caller's other VCs.

This is the ghost-code instance of "extract to reduce proof context." Reserve
it for genuinely heavy or looping ghost code—a two- or three-line assert or
basic lemma call does not warrant its own lemma.

### `Assert_And_Cut` (reduce proof context)

```ada
pragma Assert_And_Cut (Key_Property);
```

Verifies the property, then forgets all preceding context. Useful when
accumulated facts overwhelm the prover.

### Assertion policy (disable expensive ghost at runtime)

Since proofs guarantee correctness, runtime ghost execution is redundant.
Place directly in source files (not `.adc`):

In `.ads`:
```ada
pragma Assertion_Policy (Post => Ignore);
```

In `.adb`:
```ada
pragma Assertion_Policy (Ghost => Ignore, Loop_Invariant => Ignore,
                         Assert => Ignore, Post => Ignore);
```

Keep `Pre => Check` -- preconditions catch caller bugs and are cheap.

For proof-helper loops that shouldn't execute at runtime, move them
into a ghost procedure (erased entirely with `Ghost => Ignore`).

## Organizing lemmas

When the lemma set for a single subprogram grows beyond a handful
(roughly **more than 5 lemmas, or 3 very large ones**), move those
lemmas out of the parent package and into a **private ghost child
package** named `<Parent>.<Subprogram>_Lemmas`.

```ada
private package Foo.Bar_Lemmas with Ghost is
   procedure Lemma_Step_Monotonic (...) with Pre => ..., Post => ...;
   procedure Lemma_Result_In_Range (...) with Pre => ..., Post => ...;
   --  ...
end Foo.Bar_Lemmas;
```

```ada
package body Foo.Bar_Lemmas is
   procedure Lemma_Step_Monotonic (...) is null;

   procedure Lemma_Result_In_Range (...) is
   begin
      Lemma_Step_Monotonic (...);  -- lemmas call lemmas
   end Lemma_Result_In_Range;
end Foo.Bar_Lemmas;
```

Why this shape:

- **Private child sees `Foo`'s private part.** Lemma contracts routinely
  reference private types, full views of type invariants, or private
  expression functions in `Foo`. A private child has that visibility;
  a sibling package does not.
- **Hidden from clients of `Foo`.** Private children can only be
  `with`ed from `Foo`'s body (or from other private descendants of
  `Foo`), so the lemma machinery stays out of the public interface.
- **Whole-package `Ghost`.** Applying `with Ghost` to the package makes
  every declaration inside it ghost automatically -- no need to repeat
  the aspect on each lemma.

Call sites in `Foo`'s body are unchanged: `Foo.Bar_Lemmas.Lemma_X (...);`
at the proof point. If a parent has several heavy subprograms, give
each one its own child (`Foo.Bar_Lemmas`, `Foo.Baz_Lemmas`) rather than
pooling lemmas into a single package -- the scope of each child stays
focused on one caller.

**Keep the child additive.** Shared subtypes and constants that both
the parent's body *and* the lemma child need (e.g., `Cov_Entry`,
`Max_Bound`) belong in the **parent's private part** — not in the
lemma child. The private child's spec sees the parent's private part,
so lemma signatures can reference those subtypes; the parent's body
has the same visibility for its own locals. Conceptually: removing
the lemma child should leave a working program.

Do **not** drop the package-level `with Ghost` on the lemma child to
make its subtypes visible to non-ghost code. That destroys the
ghost-ness the lemmas need and puts the shared declarations in the
wrong place. If you reach for this, the subtypes shouldn't be in the
child — move them to the parent's private part.

## Workflow: Status File Updates

- **Wrote a ghost lemma** → add "Prove Lemma_Name body" to Discovered Obligations
  (even `is null` lemmas generate a proof obligation that GNATprove must discharge)
- **Introduced an axiom** (with user permission) → add "AXIOM: Axiom_Name --
  assumed, not proved" to Discovered Obligations as a permanent note
- **Added Assert_And_Cut** → add "Verify Assert_And_Cut at file:NN" to
  Discovered Obligations (the assertion itself must prove)

## Gotchas

- **Naming convention**: `Lemma_<property>` (proved), `Axiom_<property>` (assumed).
  Makes proof status visible at a glance.
- **Ghost can read non-ghost but not vice versa.** Non-ghost code cannot
  reference ghost entities.
- **Ghost procedures must have no non-ghost outputs.** No writing to non-ghost
  globals, no `out` parameters of non-ghost type.
- **Axioms are unchecked.** An incorrect axiom makes the entire proof unsound.
  Always justify why the property is true but unprovable in SPARK.

## References

- [Ghost Code](https://docs.adacore.com/live/wave/spark2014/html/spark2014_ug/en/source/specification_features.html#ghost-code) -- Ghost functions, variables, types, procedures, packages
- [SPARK Lemma Library](https://docs.adacore.com/live/wave/spark2014/html/spark2014_ug/en/source/spark_libraries.html#spark-lemma-library) -- Distributed ghost lemma procedures for arithmetic
- [Pragma Assert_And_Cut](https://docs.adacore.com/live/wave/spark2014/html/spark2014_ug/en/source/assertion_pragmas.html#pragma-assert-and-cut) -- Cutting proof context to simplify verification
- [Expression Functions](https://docs.adacore.com/live/wave/spark2014/html/spark2014_ug/en/source/specification_features.html#expression-functions) -- Inlined specification functions usable in contracts
