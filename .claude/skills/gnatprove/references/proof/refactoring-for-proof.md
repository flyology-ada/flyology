# Refactoring Code for Proof

## Concepts

### Information hiding promotes provability

SPARK verification is strictly modular: when proving a subprogram, the prover
sees callees only through their contracts — types, `Pre`, `Post`, `Global`,
`Depends`, predicates — and nothing else
(see [spark.md § Modularity is absolute](../spark/spark.md)). This is the
same principle as information hiding in software design: the rest of the system
doesn't need to know *how* a computation is performed, only *what* it
guarantees. And just as information hiding promotes flexibility by insulating
callers from implementation changes, it promotes provability by insulating
the prover from irrelevant detail.

This is exactly why lemmas work — they package a fact behind a contract and
hide the justification. The same principle applies to regular (non-ghost) code:
every extracted subprogram is a small lemma for its own body. The consequence
is that **every extraction is a contract-design exercise**: if the body needs
facts from the caller, the `Pre` must carry them; if the body establishes
facts the caller needs, the `Post` must expose them. An extraction that
"loses information" is always a contract that doesn't say enough — not
something the prover forgot.

### Cohesion and coupling are the refactoring targets

High cohesion and low coupling are the universal goals of good software design.
They govern **provability** with even more force than they govern readability:

- **Low coupling** — narrow, typed interfaces with few globals — keeps the
  prover's view of each call site small. A subprogram that reaches across
  the program forces the prover to track its effects wherever it runs.
- **High cohesion** — each subprogram does one thing — keeps its contract
  crisp. A subprogram that does three things needs a postcondition with
  three conjuncts, and every caller pays for all three even when it uses
  only one.

**SMT solvers drown in context the same way LLMs do.** The provers behind
GNATprove accumulate every in-scope fact — each local variable, each branch,
each prior assertion — into one search and try to discharge the goal from
all of it at once. Context overload causes the same failure modes as it does
in an LLM: timeouts on easy goals, budget burned on irrelevancies, and
unstable results that regress under unrelated edits. The cure is to shrink
the context, not to coach the solver with more hints. Every subprogram call
is a **hard cut** (the prover sees the callee's contract, not its body);
every `Assert_And_Cut` is a **soft cut** (facts disappear after the assertion).

When a proof is stubbornly failing, the first questions are diagnostic, not
technical: *Is this subprogram doing too many things?* (cohesion) *Does it
reach into too much state?* (coupling). Those are the refactoring targets —
the contract and the assertion come later.

### Decompose before annotating

When a subprogram has unproved checks, the first question is: **is this
subprogram too big, or doing too many things?** If yes, decompose it before
reaching for assertions, lemmas, or higher proof levels. Extract a coherent
chunk of logic into its own subprogram with a clear contract. The caller
body becomes simpler (the prover sees the contract, not the extracted code),
and the extracted subprogram is proved in isolation with only its own local
context.

There is a cost: each new subprogram call is a cut point in the analysis.
Preconditions and postconditions are required, and the prover must verify them.
But this cost is almost always worth paying because:

1. **The prover sees less** — each subprogram's proof context is smaller
2. **Contracts are reusable** — callers get the postcondition for free
3. **The code is better** — the same decomposition that aids proof aids
   readability, testing, and reuse

Decomposition is an early step, not a last resort. Evaluate each subprogram
with unproved checks for decomposition before annotating.

### Why monolithic code fails proof

Consider a 60-line procedure that parses input, validates it, transforms it,
and writes output. When the prover fails on the output write, it has 60 lines
of context: parsing temporaries, validation flags, transformation intermediates.
A lemma or assertion might rescue the proof — but extracting `Parse`, `Validate`,
and `Transform` into their own subprograms means the output section sees only
their postconditions. The proof often becomes trivial.

The monolithic form is low-cohesion by construction (four concerns in one
body) and high-coupling by construction (every local touched by one concern
is visible to the next). Decomposing fixes both dimensions in the same
refactoring, which is why it is such a high-yield move when proof is hard.

## Patterns

### Extract subprograms to reduce proof context

The most impactful refactoring for proof. Identify a self-contained block of
logic within a monolithic subprogram and extract it.

```ada
-- Before: monolithic, prover sees everything
procedure Process (Input : String; Result : out Record_Type) is
   Tokens : Token_Array := ...;
begin
   -- 20 lines of tokenization
   -- 15 lines of validation
   -- 25 lines of transformation into Result
   -- Prover fails here: too much context from tokenization/validation
end Process;

-- After: decomposed, each proof is local
procedure Tokenize (Input : String; Tokens : out Token_Array) with
  Post => Valid_Tokens (Tokens);

procedure Validate (Tokens : Token_Array) with
  Pre  => Valid_Tokens (Tokens),
  Post => All_In_Range (Tokens);

procedure Transform (Tokens : Token_Array; Result : out Record_Type) with
  Pre  => All_In_Range (Tokens),
  Post => Consistent (Result);
```

Each subprogram is proved in isolation. `Process` sees only contracts.

### Extract loop bodies into subprograms

If a loop body has no data dependencies on prior iterations — i.e., each
iteration operates independently on the current element — it's a candidate for
extraction. This is especially true for `for E of A` loops where the body is
effectively a map operation.

```ada
-- Before: loop body inline, prover must reason about body + invariant together
for I in A'Range loop
   -- 15 lines of per-element transformation
   A (I).Field_1 := Compute_X (A (I));
   A (I).Field_2 := Derive_Y (A (I).Field_1, A (I).Field_3);
   A (I).Status  := (if A (I).Field_2 > Threshold then Valid else Inactive);
   pragma Loop_Invariant (...);
end loop;

-- After: body extracted, loop is trivial
procedure Transform_Element (E : in out Element_Type) with
  Post => E.Status in Valid | Inactive
          and then E.Field_1 = Compute_X (E'Old)
          and then E.Field_2 = Derive_Y (E.Field_1, E'Old.Field_3);

for I in A'Range loop
   Transform_Element (A (I));
   pragma Loop_Invariant (...);
end loop;
```

The extracted subprogram is proved once, in isolation. The loop invariant only
needs to reason about the postcondition, not the implementation. This isn't
necessary for short loop bodies, but for anything non-trivial it simplifies the
proof and often improves the code — a named operation with a clear contract is
reusable and self-documenting.

### Strengthen types to eliminate repeated contracts

```ada
-- Before: same constraint in every contract
procedure P (Alt : Real64) with Pre => Alt in 0.0 .. MAX_ALTITUDE;
procedure Q (Alt : Real64) with Pre => Alt in 0.0 .. MAX_ALTITUDE;

-- After: constraint lives in the type
subtype Positive_Altitude is Real64 range 0.0 .. MAX_ALTITUDE;
procedure P (Alt : Positive_Altitude);
procedure Q (Alt : Positive_Altitude);
```

GNATprove gets bounds for free from the type. Trade-off: every assignment to the
subtype must be proved in-range.

### Constrained return types eliminate manual invariants

```ada
-- Before: manual invariant needed
Count : Integer := 0;
pragma Loop_Invariant (Count <= 256);

-- After: type constraint replaces the invariant
subtype Char_Index is Integer range 0 .. 256;
Count : Char_Index := 0;
```

### Replace defensive code with preconditions

SPARK antipattern: guarding against bad inputs inside the body.

```ada
-- Before: defensive, creates unprovable branches
procedure P (X : Integer) is
begin
   if X < 0 then
      raise Constraint_Error;
   end if;
   -- ... use X ...
end P;

-- After: precondition excludes invalid inputs, body is straight-line
procedure P (X : Integer) with
  Pre => X >= 0;
```

The caller must prove the precondition, but often it follows from the caller's
own types or earlier checks — eliminating runtime guards entirely.

### Restructure arithmetic to avoid overflow

```ada
-- Before: I*I overflows for large I
while I * I <= N loop

-- After: algebraically equivalent, no overflow
while I <= N / I loop
```

When rewriting isn't possible, widen to a larger type and convert back.
See [overflow-patterns.md](overflow-patterns.md) for the full catalog.

### Single-pass instead of two-pass

Two-pass algorithms (count then fill) require proving the count from pass 1
matches the indexing in pass 2 — usually via a ghost variable and a complex
invariant.

```ada
-- Before: two passes, complex proof obligation
Count := Count_Tokens (Input);
Result := new Token_Array (1 .. Count);
-- must prove Fill fills exactly Count elements

-- After: single pass into worst-case buffer, return slice
Buffer : Token_Array (1 .. Max_Tokens);
Last   : Natural := 0;
-- ... fill Buffer (1 .. Last) in one pass ...
return Buffer (1 .. Last);
```

### Split loops that mix concerns

A loop that maintains two unrelated properties needs an invariant for each, and
the prover must show both survive every statement. Splitting into two loops gives
each a simpler invariant.

```ada
-- Before: one loop, two concerns, complex invariant
for I in A'Range loop
   Normalize (A (I));
   Sum := Sum + A (I);
   pragma Loop_Invariant (All_Normalized (A, A'First, I)
                          and Sum = Partial_Sum (A, A'First, I));
end loop;

-- After: two loops, each trivially provable
for I in A'Range loop
   Normalize (A (I));
   pragma Loop_Invariant (All_Normalized (A, A'First, I));
end loop;
for I in A'Range loop
   Sum := Sum + A (I);
   pragma Loop_Invariant (Sum = Partial_Sum (A, A'First, I));
end loop;
```

### Extract helper functions to isolate proof

Complex boolean expressions in contracts or loop invariants are hard for the
prover to decompose. Extract them into expression functions — the prover unfolds
the definition automatically.

```ada
function Is_Partitioned (A : Arr; Pivot : Index) return Boolean is
  ((for all I in A'First .. Pivot => A(I) <= A(Pivot))
   and (for all J in Pivot .. A'Last => A(J) >= A(Pivot)))
with Ghost;
```

Callers write `Is_Partitioned(A, P)` instead of the full quantified expression.

## When NOT to refactor

- **The property is genuinely relational** (relates two parameters, or a parameter
  to a global): this belongs in a contract, not a type.
- **The code structure is required by the domain** (protocol state machine, specific
  algorithm): annotate rather than distort the design.
- **A simple Assert or lemma call resolves the failure**: don't restructure when
  a one-line hint suffices.

## References

- [contracts.md](../spark/contracts.md) — Preconditions over defensive code; types over contracts
- [overflow-patterns.md](overflow-patterns.md) — Full catalog of arithmetic restructuring
- [loops.md](loops.md) — Loop invariant patterns including buffer+slice
- [workflow.md](workflow.md) — Preconditions vs. code restructuring decision guidance
