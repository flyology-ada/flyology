# Package State (and Singletons)

A package with internal state holds *global* data. A **singleton** is the
deliberate case: one package whose state is the single, unique instance of that
data, hosted behind an information-hiding interface. This is not an
anti-pattern. The state simply obeys the same modular rule as any global — see
[spark.md § Modularity is absolute](spark.md).

## Naming hidden state in contracts

A subprogram's effects on state outside its parameters must appear in its
`Global`/`Depends`. For hidden package state that is a tension: the contract has
to name the state, but must not expose the package's private variables or types.

State abstraction resolves it. Declare an opaque `Abstract_State` name in the
spec and give its `Refined_State` — the real constituents — in the body.
Contracts mention only the abstract name:

```ada
package Cache with
  Abstract_State => State,      --  one opaque name, visible to callers
  Initializes    => State
is
   procedure Put (K : Key; V : Value) with Global => (In_Out => State);
   function  Get (K : Key) return Value with Global => (Input => State);
end Cache;

package body Cache with
  Refined_State => (State => (Table, Count))   --  the real constituents
is
   Table : Map;
   Count : Natural;
   --  ...
end Cache;
```

The payoff is that the constituents can change — add one, remove one,
re-partition them — without touching a single contract, because the contracts
speak only of `State`. A representation change stays inside the body instead of
cascading up the call tree. GNATprove checks the refinement against the body's
actual effects, so the abstraction stays honest.

(State that is shared or volatile is named the same way but marked
`with External`; see [ffi.md](ffi.md).)

## The interface is an opportunity

Because the state is reached only through the package's operations, the
interface is the place to specify how the state may be used: attach predicates
that report its status (`Is_Initialized`, `Is_Open`, …) and codify the protocol
with preconditions on the operations. A predicate needed only for proof can be
`Ghost`.

## The protocol must be threaded, exactly like a parameter

Modularity means a deep call site does not know what an outer caller
established. If `main` initializes the state and calls `Foo → Bar → Baz`, SPARK
does not know in `Baz` that it was initialized. Recover the fact one of two
ways.

Guard at the call site — the guard discharges the precondition within that
subprogram:

```ada
if Engine.Is_Initialized then
   Engine.Run;        --  Pre => Is_Initialized, discharged by the guard
end if;
```

Or thread it as a precondition down the call chain, so the deep call needs no
runtime test:

```ada
procedure Foo with Pre => Engine.Is_Initialized;   --  and likewise Bar, Baz
--  Baz then calls Engine.Run directly; Is_Initialized may be Ghost.
```

This is the same threading a formal parameter would require. The only
difference is visibility: with a parameter the obligation is staring at you;
with package state it is easy to forget it is there at all.

## Bottom line

Use package state and singletons where unique global data genuinely wants a
single home. But beware: **its usage protocol threads through preconditions**
exactly as a formal parameter's would — plan for it.

## See also

- [spark.md § Modularity is absolute](spark.md) — the general rule; "Same rule for globals"
- [access-types.md](access-types.md) — a global object of a type subject to ownership fights ownership tracking
