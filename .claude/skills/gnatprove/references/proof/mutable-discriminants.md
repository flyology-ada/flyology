# Discriminant Check on a Mutable Discriminated Record

A `discriminant check might fail` on a whole-object assignment that *changes* a
discriminant — e.g. `X := (B => False)` for `type T (B : Boolean := True)` —
means that the prover cannot show the target has **mutable** discriminants.
A record with *defaulted* discriminants is mutable only when the
object is unconstrained; a constrained object (`Y : T (True)`) may never change
its discriminant. For a parameter, constrainedness is inherited from
the *actual*, so modular analysis must assume the worst and the check fails.

Two fixes, by visibility:

- **Type is visible** — require mutability in the contract:
  ```ada
  procedure Update (X : in out T) with Pre => not X'Constrained;
  ```

- **Type is private and the discriminant must not be exposed** — `'Constrained`
  is illegal on the partial view (`type T is private` is definite, so the
  attribute prefix "must be an object of a discriminated type").
  Instead, wrap the discriminated type as a **component** of the full
  view. A record component whose subtype has defaulted discriminants is *always*
  mutable, so the assignment proves with no precondition and the partial view is
  unchanged:
  ```ada
  private
     type Inner (B : Boolean := True) is record
        case B is
           when True  => Content : Integer;
           when False => null;
        end case;
     end record;
     type T is record           --  partial view stays `type T is private;`
        Data : Inner;
     end record;
  ```
  The body then assigns `X.Data := (B => False)`, which always proves.

Avoid the temptation to guard the body with `if not X'Constrained then ...`:
the full view makes `'Constrained` legal inside the body, but the guard
silently turns the update into a no-op for constrained actuals — the clamping
anti-pattern in another costume.
