# Writing SPARK

This section covers the SPARK language — contracts, types, ghost code, and access
types — and the coding principles that make SPARK code provable.

## Core Principles

### Modularity is absolute

SPARK verification is strictly modular. The prover analyses each subprogram
in isolation, and the *only* information that crosses a subprogram boundary
is carried by its **contract**:

- **Types and subtypes** on parameters and return (including their range
  constraints, type predicates, and type invariants)
- **`Pre`, `Post`, and `Contract_Cases`** (with `'Old` and `'Result`)
- **`Global` and `Depends`** (for effects on state outside the parameters)

Nothing else crosses. Not local variables, not intermediate computations,
not facts the body "obviously" establishes. If the body knows something
callers need, the `Post` must say it. If the body needs something from the
caller, the `Pre` must require it.

**Assume-guarantee.** Who proves and who assumes is fixed. At a call
`Foo → Bar`, `Foo` *proves* `Bar`'s precondition and *assumes* its
postcondition; `Bar` *assumes* its precondition and *proves* its
postcondition. So a `Pre` is an obligation discharged by the caller and relied
on by the body, and a `Post` is an obligation discharged by the body and relied
on by the caller. This assume-guarantee split is the foundation of deductive
verification — and it is what makes a foreign (non-SPARK) callee a special
case: with no SPARK body, its `Post` is only ever *assumed*, never proved (see
[ffi.md](ffi.md)).

The only exceptions are expression functions declared in the spec (their
body expression becomes an implicit `Post`, so it *is* carried in the
contract, just generated automatically) and subprograms annotated with
`pragma Annotate (GNATprove, Inline_For_Proof, ...)` (which explicitly
asks the prover to inline the body across call sites). Outside those two
cases, assume the body is invisible.

**Diagnostic consequence.** When a refactor or extraction seems to "lose
information" — a lemma whose body suddenly won't prove, a caller that can
no longer discharge a check that held before the extraction, a regression
after a change to a callee's body — the cause is always that the contract
does not carry what's needed. Tighten `Pre`, strengthen `Post`, add a
frame postcondition for unmodified state, or push the constraint into the
type. Do not conclude that the solver "forgot" the fact or that
"information didn't make it across": modularity is a language guarantee,
not a solver quirk.

**Same rule at the loop scale.** Loops are cut points too: the only facts
that survive a loop are type constraints and whatever a `Loop_Invariant`
carries. The principle is identical, only the channel changes — the
contract at a subprogram boundary, the `Loop_Invariant` at a loop
boundary. See [loops.md § Loops are cut points](../proof/loops.md#loops-are-cut-points).

### Types over contracts

If a range constraint applies to a value everywhere — in a record field, every
caller, every use — encode it in the subtype rather than threading it through every
`Pre`/`Post`/invariant. Subtypes are checked at every assignment; contracts are
only checked at call boundaries. Fewer contracts means fewer proof obligations.

### Preconditions over defensive code

In non-SPARK code, the standard practice is defensive programming: guard against
bad inputs inside the body, then raise or return an error. **This is an antipattern
in SPARK.** Defensive guards create branches that must be proved and error paths
callers must handle. Use preconditions to exclude invalid inputs instead — the body
then has clean, straight-line logic. Callers prove the precondition holds before
calling, often from type bounds, earlier checks, or loop conditions.

### Forbidden without explicit user permission

| What | Why not |
|------|---------|
| `SPARK_Mode (Off)` on a body | The body is entirely unverified — not a workaround, giving up. Most operations that *seem* unverifiable are not; genuine exceptions are narrow (heap-mutating operations, or an unverifiable leaf — a wall-clock read, a cryptographic hash, raw disk I/O — isolated behind an in-SPARK spec so callers stay proved). Whether a given case truly qualifies is a decision to reach **with the user**, never on your own: until this skill is exhaustive, there may always be a `SPARK_Mode => On` technique you do not yet know. |
| Value clamps (e.g. `X := T'Min(X, MAX)`) | Silently changes behavior for out-of-range inputs. Creates dead code unreachable in testing — anathema in certification work. Use subtypes or preconditions to push the constraint to the caller instead. |

## Reference Files

| File | When to read |
|------|--------------|
| [contracts.md](contracts.md) | `Pre`, `Post`, `Global`, `Depends`, `Contract_Cases`; frame postconditions; the clamping anti-pattern |
| [ghost-code-and-lemmas.md](ghost-code-and-lemmas.md) | Ghost variables and functions; `pragma Assert`; lemmas vs. axioms; hint strength ordering |
| [access-types.md](access-types.md) | Ownership model; borrowers and observers; null exclusion; allocators |
| [package-state.md](package-state.md) | Package-internal state, including **Singletons**: hosting unique global data behind an interface; threading its usage protocol through preconditions; when ownership forces a parameter instead |
| [idioms.md](idioms.md) | Expression-level idioms: unnecessary conversions and other Ada writing hygiene |
| [ffi.md](ffi.md) | Modelling state across a C/Rust boundary: `Abstract_State with External`; why a value reader over mutable far-side state needs `Volatile_Function`, not a silently-unsound `Global => null`; where the C imports live (spec-only child); why FFI warnings are load-bearing |
| [ownership-and-reclamation.md](ownership-and-reclamation.md) | Putting a resource private type under ownership (`Needs_Reclamation` / `Is_Reclaimed`) so a leak is a proof failure; the `System.Address`-isn't-ownable gotcha and the shadow access token; the reclaim finalizer's `Depends` |
