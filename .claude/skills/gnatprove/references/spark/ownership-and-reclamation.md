# Ownership and Reclamation

The `Ownership` annotation puts a private type under SPARK's
[Memory Ownership Policy](access-types.md) — single owner, move semantics, no
aliasing — even when SPARK cannot see the full view. Adding the
`"Needs_Reclamation"` specifier layers reclamation on top: GNATprove proves the
resource the type describes (a file, a socket, a C handle) is released before the
object is dropped, so a leak becomes a proof failure. The mechanism is the
[`Ownership` annotation](https://docs.adacore.com/live/wave/spark2014/html/spark2014_ug/en/appendix/additional_annotate_pragmas.html#annotation-for-enforcing-ownership-checking-on-a-private-type).

## Making a resource type owned

Annotate the type and give it an `Is_Reclaimed` predicate that is True once the
resource is released; GNATprove checks it holds wherever the object is dropped
(unless it was moved):

```ada
type T is limited private
  with Annotate                  => (GNATprove, Ownership, "Needs_Reclamation"),
       Default_Initial_Condition => Is_Reclaimed (T);

function Is_Reclaimed (X : T) return Boolean
  with Ghost, Annotate => (GNATprove, Ownership, "Is_Reclaimed");
```

(An alternative to the predicate is a `"Reclaimed_Value"` constant: an object is
reclaimed exactly when it equals that constant.)

The private part must then be `SPARK_Mode => Off` — the full view is
opaque and the whole type is treated as owned.

## `System.Address` and `Interfaces` pointers

An object of type `System.Address` or, e.g., `Interfaces.C.Strings.char_ptr` is
not subject to ownership. While these types represent pointers on the other
side of an FFI boundary, SPARK does not view them as access types. You cannot
apply
ownership annotations to these types directly.

The correct approach is to create a private type whose full view is outside of
SPARK, with `SPARK_Mode => Off`. This is the pattern taken in the SPARKlib for
`SPARK.C.Strings`:

```ada
   type chars_ptr is private
   with
     Annotate => (GNATprove, Ownership, "Needs_Reclamation"),
     Annotate => (GNATprove, Predefined_Equality, "Only_Null"),
     Default_Initial_Condition => Is_Null (Chars_Ptr);
   pragma Preelaborable_Initialization (chars_ptr);

   Null_Ptr : constant chars_ptr
   with
     Annotate => (GNATprove, Ownership, "Reclaimed_Value"),
     Annotate => (GNATprove, Predefined_Equality, "Null_Value");

   function Is_Null (Item : chars_ptr) return Boolean
   with Ghost, Post => Is_Null'Result = (Item = Null_Ptr);
```

and in the private part:

```ada
   pragma SPARK_Mode (Off);
   type chars_ptr is new Interfaces.C.Strings.chars_ptr;

   Null_Ptr : constant chars_ptr := chars_ptr (Interfaces.C.Strings.Null_Ptr);

   function Is_Null (Item : chars_ptr) return Boolean
   is (Item = Null_Ptr);
```

## The reclaim finalizer

The finalizer resets the object to reclaimed and consumes its old value, so its
`Depends` takes the sink shape — the same one used for a recursive `Free`:

```ada
procedure Close (X : in out T)
  with Post    => Is_Reclaimed (X),
       Depends => (X => null,     --  new value is a constant (reclaimed)
                   null => X);    --  old value consumed (freed / crosses to C)
```

Without `null => X`, every caller that finalizes a local `T` gets a "set but not
used" flow warning. See [contracts.md § Dependency clauses](contracts.md) for the
shape, and [package-state.md](package-state.md) for why the resource is threaded
as a parameter rather than held in package state.

## See also

- [access-types.md](access-types.md) — the Memory Ownership Policy this builds on
- [contracts.md](contracts.md) — the `Depends` dependency clauses
- [ffi.md](ffi.md) — modelling the foreign state the handle reaches
