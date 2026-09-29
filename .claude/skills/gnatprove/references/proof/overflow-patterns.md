# Overflow in Arithmetic

## Concepts

Overflow is the single most common source of proof failures. Under the default
STRICT overflow mode, SPARK checks every intermediate arithmetic result against
the type's bounds. This means expressions that are mathematically correct can
still fail proof if an intermediate value exceeds the type range -- even if the
final result fits.

(SPARK also supports MINIMIZED and ELIMINATED overflow modes that use wider or
arbitrary-precision intermediates, reducing this problem. See the
[Overflow Modes](https://docs.adacore.com/live/wave/spark2014/html/spark2014_ug/en/source/overflow_modes.html)
UG page. The patterns below assume STRICT mode, which is the default.)

The core principle: **restructure expressions so every intermediate is provably
in-range**, rather than hoping the prover can reason about the final result.

Two key techniques:
1. **Algebraic rewriting**: replace an expression with a mathematically equivalent
   form whose intermediates are smaller (e.g. `I <= N/I` instead of `I*I <= N`)
2. **Widening**: compute in a larger type, then convert back (e.g. sum `Integer`
   values in `Long_Long_Integer`, then range-check the result)

When neither works, a **precondition** bounding the inputs is appropriate --
this is a legitimate semantic constraint, not a workaround. See
[contracts.md](../spark/contracts.md) for guidance on when preconditions are the right
tool vs. restructuring the code.

Overflow in **contract expressions** is also checked. Write `X <= Integer'Last - Y`
not `X + Y <= Integer'Last` in preconditions. SPARK's check messages will often
suggest a correct resolution to this specific class of problem.

## Patterns

### Squaring: `I*I <= N` overflows -- use division form

```ada
while I <= N / I loop  -- safe: no overflow
```

### First+1: `Array'First + 1` overflows at `Positive'Last`

Handle the first element before the loop, guard the range:

```ada
Result (A'First) := A (A'First);
if A'First < A'Last then
   for I in A'First + 1 .. A'Last loop ...
end if;
```

### Half-length: `(N + 1) / 2` overflows at `Positive'Last`

```ada
Half := N / 2 + (if N mod 2 = 0 then 0 else 1);
-- or equivalently:
Half := N / 2 + N mod 2;
```

### String scanning: `S'Last + 1` or `Index + Len` overflows

Add a precondition:

```ada
Pre => S'Last < Positive'Last
-- for multi-char lookahead:
Pre => S'Last <= Positive'Last - 1
```

### Relative indexing: subtract before adding

```ada
K := I - S'First + 1;  -- safe: I >= S'First in loop, so subtraction >= 0
-- not: K := 1 + (I - S'First)  -- also safe but less obvious
```

### Multiplication bounds in invariants: product form over division

Integer division truncates, so `X <= Y / 3` may allow one extra value.
Use the product form for exact bounds:

```ada
pragma Loop_Invariant (Count * 3 <= Step + 2);
```

### Widening: use `Long_Long_Integer` for intermediate sums

```ada
Sum : Long_Long_Integer :=
   Long_Long_Integer (A(I)) + Long_Long_Integer (A(J));
```

Multiple 32-bit integers sum safely in 64 bits. Convert back after
range-checking.

### Division-then-convert: bound numerator by `Target'Last * Min_Denom`

```ada
Pre => abs(Denom) >= TOLERANCE
  and then Num in 0.0 .. Real64(Real32'Last) * TOLERANCE;
```

Ensures `Num / Denom <= Real32'Last`, making `Real32(Num / Denom)` provable.

## Gotchas

- **Contract expressions overflow too.** Write `X <= T'Last - Y` not `X + Y <= T'Last`.
- **Empty ranges don't execute but bounds are still evaluated.** `for I in A'First+1 .. A'Last`
  evaluates `A'First+1` even when the range is empty. Guard with `if A'First < A'Last`.
- **`mod` and `rem` can't overflow** (result bounded by divisor), but the dividend
  expression might.
- **Aggregate bounds matter.** `(Positive'Last - 2 => 1, Positive'Last - 1 => 2, Positive'Last => 3)`
  tests near-limit indices. Always include such cases in test assertions. Also test
  near-limit values (`Integer'First`, `Integer'Last`) and edge cases (empty arrays,
  single-element arrays). `Array'First + 1` overflow bugs only manifest at extreme indices.

## References

- [Overflow Modes](https://docs.adacore.com/live/wave/spark2014/html/spark2014_ug/en/source/overflow_modes.html) -- STRICT, MINIMIZED, and ELIMINATED overflow checking
- [Scalar Ranges](https://docs.adacore.com/live/wave/spark2014/html/spark2014_ug/en/source/type_contracts.html#scalar-ranges) -- Using type ranges as overflow-preventing contracts
- [Writing Contracts for Program Integrity](https://docs.adacore.com/live/wave/spark2014/html/spark2014_ug/en/source/how_to_write_subprogram_contracts.html#writing-contracts-for-program-integrity) -- Preconditions to prevent runtime errors
- [Silver Level - Absence of Run-time Errors](https://docs.adacore.com/live/wave/spark2014/html/spark2014_ug/en/usage_scenarios.html#silver-level-absence-of-run-time-errors-aorte) -- Proving absence of overflow and range checks
