# Foreign Function Interfaces (FFI)

Modelling state that lives on the far side of a language boundary (C, Rust,
even Ada to a degree) so SPARK's analysis stays honest. Builds on
[package-state.md](package-state.md) (state abstraction) and
[spark.md](spark.md) (assume-guarantee).

## The boundary is an assumption

SPARK never sees a foreign body. By assume-guarantee, a call proves the
callee's `Pre` and *assumes* its `Post`/`Global`; for a foreign callee there is
no body to discharge the `Post`, so it is only ever assumed. A `-gnata` test
build executes that boundary contract and is the only runtime validation of the
assumption.

The rule that governs everything below: **SPARK is sound only about your model
of the far side.** You supply that model through the contracts on the imports —
and a wrong model yields unsound proof, sometimes with no diagnostic at all.

**SPARK necessarily trusts you to model what's happening on the other side of
the FFI boundary.** This is not a bug/failure of SPARK; it is a correct design
decision.

## External state: the far side that isn't yours

When the foreign side owns genuinely shared or asynchronously-changing state — a
database file other OS processes can write, a socket — model it as an *external*
abstract state, refined to null (its constituents live across the boundary):

```ada
package Sqlite_Vec_Spark with
  SPARK_Mode     => On,
  Abstract_State => (DBMS with External),   -- lives across the C boundary
  Initializes    => DBMS
is
   procedure Close (DB : in out Database)
     with Global  => (In_Out => DBMS),
          Depends => (DBMS =>+ null, DB => null, null => DB);  -- see contracts.md
```

Every import that mutates the far-side state carries `Global => (In_Out => S)`.
The payoff: an External write is always *effective* (an async peer might observe
it), so a `Close` whose handle is then discarded reads as a real effect instead
of being flow-flagged "has no effect". (For the `Depends` shape, see
[contracts.md § Dependency clauses](contracts.md).)

Reach for External only when the far side really is shared or async. A
self-contained transform behind a handle with no async peer — an embedding model
you load, call, and free — has no such state: its imports are honestly
`Global => null` with no abstract state at all.

### A reader over mutable far-side state is not pure

The trap is a value reader — a function returning something the foreign side
computes from mutable state (a row count, the last inserted id, a column of the
current cursor row). Declaring it `Global => null` tells SPARK it is a pure
function, so SPARK may assume `f (x) = f (x)` across calls. That is false, and
there is **no warning**: a silent soundness hole.

The value moves outside SPARK's visible writes, so SPARK must be told not to
assume it stable. Model the state `Async_Writers => True` (it changes on its own)
and `Effective_Reads => False` (reading it is not itself a mutation), and mark the
reader a `Volatile_Function`:

```ada
--  DON'T: SPARK assumes Changes (DB) is constant across calls — unsound.
function Changes (DB : Database) return Natural with Global => null;

--  DO: a volatile read SPARK will not assume stable.
--  Abstract_State => (DBMS with External => (Async_Writers   => True,
--                                            Effective_Reads => False, ...))
function Changes (DB : Database) return Natural
  with Volatile_Function, Global => (Input => DBMS);
```

A `Volatile_Function` call is restricted to simple contexts — the right-hand side
of an assignment, an actual parameter — so `Id := Changes (DB);` is legal but
`Changes (DB) + 1` is not. Where a reader must appear inside a larger expression,
make it a procedure with an `out` result, or capture it into a local first.

Note `Effective_Reads` is the mechanical gate, distinct from the soundness point:
bare `with External` defaults it to True, and *no* function — volatile or not —
may read effective-read state, because that read is itself a write. Leaving it at
the default produces a legality error (`function … with volatile input global …
with effective reads is not allowed in SPARK`), not the silent unsoundness above.

## Where the C imports live

A null-refined external state has no constituents in the body that refines it
(`Refined_State => (DBMS => null)`), and SPARK only lets the abstract name be
named *outside* its refinement region. So an import carrying
`Global => (In_Out => DBMS)` cannot be declared in that body.

One possible solution to move the imports to a **child** package,
public or private, where the name is legal:

```ada
private package Sqlite_Vec_Spark.Bridge with SPARK_Mode => On is
   procedure Close_V2 (Db : System.Address)
     with Import, Convention => C, External_Name => "sqlite3_close_v2",
          Global => (In_Out => DBMS), Always_Terminates => True;
end Sqlite_Vec_Spark.Bridge;
```

The child is **spec-only**: an `Import` aspect must sit n the declaration (the
convention has to be known where callers see the subprogram), so a body cannot
complete it, and the imports *are* the child's whole content. The parent body is
left as pure proven wrappers with no `Import` in sight.

Another approach is to declare the abstract state in a nested package, so the
enclosing scope can have `SPARK_Mode => On`.

## Warnings at an FFI boundary must not be ignored

When a call chain bottoms out in foreign code, treat SPARK's flow warnings as
findings, not noise. A "statement has no effect" or "unused" on a call you *know*
touches the far side almost always means your model of the external state is
wrong or missing — the honest fix corrects the model (add the `Global`, mark the
state External, make the reader volatile), never `pragma Warnings (Off)`. This is
where soundness depends most on you: SPARK cannot see across the boundary, so a
warning suppressed here can bury a real defect.

## See also

- [package-state.md](package-state.md) — `Abstract_State`/`Refined_State`; the state-abstraction mechanism External extends
- [spark.md](spark.md) — assume-guarantee; the `SPARK_Mode`/suppression discipline
- [contracts.md](contracts.md) — `Global`, and the `Depends` dependency clauses
- [proof-debugging.md](../proof/proof-debugging.md) — investigating warnings and unproved checks
