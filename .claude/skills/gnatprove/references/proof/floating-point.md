# Floating-Point Proofs

## Concepts

### SPARK's FP model

SPARK assumes IEEE 754 with Round-Nearest-Even (RNE) rounding. Proof obligations
ensure every intermediate result is finite -- no infinity, no NaN. This means
the prover must bound every arithmetic expression within the type's range.

On x86, compile with `-msse2 -mfpmath=sse` and `-ffp-contract=off` to match
SPARK's model (avoid x87 extended precision and FMA fusion).

### The prover's weakness: nonlinear arithmetic

Multiplication, division, modulo, and exponentiation are hard for SMT solvers.
For linear expressions (addition, subtraction, comparison), the prover is strong.
For nonlinear expressions, you'll often need to help.

Strategies, in order:
1. **Preconditions** bounding inputs so the result range is obvious
2. **`pragma Assert` breadcrumbs** breaking complex expressions into steps
3. **`SPARK.Lemmas`** for monotonicity (relational) facts
4. **Custom ghost lemmas** for domain-specific bounds

### Trig near singularities

`Tan(x)` near Pi/2 is **not a problem**. Pi/2 is irrational; no IEEE 754 float
exactly equals it. Every representable float is strictly away from the pole, so
`Tan` returns finite. GNATprove handles this correctly. Don't add unnecessary
guards.

## Patterns

### Division-then-convert

See [overflow-patterns.md](overflow-patterns.md) -- the pattern is:
bound the numerator by `Target'Last * Min_Denominator`.

### Encoding bounds in types

```ada
MAX_SLANT : constant := 6.0e7;  -- must be a literal or static expression
subtype Slant_M is Real64 range 0.0 .. MAX_SLANT;
```

GNATprove gets the bound for free from the type.

### Lemma library for monotonicity

The `SPARK.Lemmas.*_Arithmetic` packages provide monotonicity lemmas. Example
(integer version; FP equivalents may exist in `Float_Arithmetic` / `Long_Float_Arithmetic`):

```ada
Lemma_Div_Is_Monotonic (Val1 => X, Val2 => Y, Denom => Z);
-- establishes: X <= Y implies X/Z <= Y/Z (Z > 0)
```

Check the actual package spec for available FP lemmas -- the UG documents the
integer versions exhaustively but not all FP lemma names.

Use for relational facts. Don't use for simple range facts (preconditions suffice).

## Gotchas

- **Literal bounds required.** Subtype bounds must be numeric literals or static
  expressions. `constant := 6.0e7` works. `constant Real64 := 1.0 / Sin(X)` does not.
- **Compiler flags matter.** Without `-msse2 -mfpmath=sse -ffp-contract=off`,
  runtime behavior may diverge from SPARK's model.
- **Multiple nonlinear ops compound difficulty.** Break chains into intermediate
  variables with `pragma Assert` on each step's range.

## References

- [Semantics of Floating Point Operations](https://docs.adacore.com/live/wave/spark2014/html/spark2014_ug/en/appendix/semantics_of_floating_point_operations.html) -- IEEE 754 compliance, rounding, NaN/infinity
- [SPARK Lemma Library](https://docs.adacore.com/live/wave/spark2014/html/spark2014_ug/en/source/spark_libraries.html#spark-lemma-library) -- Floating-point arithmetic lemmas
- [Overflow Modes](https://docs.adacore.com/live/wave/spark2014/html/spark2014_ug/en/source/overflow_modes.html) -- STRICT/MINIMIZED/ELIMINATED modes for signed integer arithmetic
