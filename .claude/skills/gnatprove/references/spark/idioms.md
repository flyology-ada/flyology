# SPARK Idioms

Focused rules for writing clean SPARK expressions. Each section covers one
idiom: the anti-pattern, why to avoid it, and the preferred form. New items
should follow the same shape.

## Do not upcast a subtype to its parent

A value of subtype `S` is a value of its parent type. Operators, membership
tests, and comparisons apply without an explicit conversion. Writing the
conversion is noise that obscures intent.

```ada
subtype Bounded_Float is Float range -Max_FPFt_12 .. Max_FPFt_12;
E11 : Bounded_Float;

--  Noise — the conversion does nothing
if Float (E11) in -Max_FPFt_12 .. Max_FPFt_12 then ...

--  Preferred
if E11 in -Max_FPFt_12 .. Max_FPFt_12 then ...
```

The same rule applies to array subtypes, record subtypes, and derived types
where the operation is inherited. Reach for an explicit conversion only when
the expression genuinely needs a value at a different type.

## Clamping Anti-Pattern

**Do NOT introduce clamps to make proofs easier.** A clamp silently changes
behavior for out-of-range inputs:

```ada
-- BAD: silently changes behavior, creates untestable dead code
Altitude := Real64'Min (Raw_Altitude, MAX_ALTITUDE);
-- The "else" branch (Raw_Altitude > MAX_ALTITUDE) is dead code that
-- can never be tested. In certification, this is unacceptable.

-- GOOD: make the constraint visible as a precondition or subtype
subtype Bounded_Altitude is Real64 range 0.0 .. MAX_ALTITUDE;
procedure Process (Alt : Bounded_Altitude);
-- Callers must prove Alt is in range. The constraint is visible,
-- testable, and documented.
```

Why this matters: clamps create branches where one arm handles "impossible"
inputs. This dead code cannot be exercised in testing, violating coverage
requirements in certified systems. Worse, the clamp may mask a real error in
the calling code.

The parallel with `pragma Assume` is exact: both make the proof go through
by hiding a gap, rather than closing it. Use subtypes or preconditions to push
constraints to callers, where they become visible proof obligations.
