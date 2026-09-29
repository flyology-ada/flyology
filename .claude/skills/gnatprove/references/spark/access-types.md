# Access Types, Ownership, and Borrowing

## Concepts

### Single-owner, move-semantics model

SPARK enforces an ownership policy analogous to Rust: every mutable heap-allocated
cell has exactly one owner at any point. Assigning an access-to-variable value
**transfers ownership** (a "move") -- the source loses all read/write permissions
until reassigned. This eliminates aliasing and makes formal verification tractable.

The ownership rules apply to **named access-to-variable types** (both pool-specific
and general). *Named* access-to-constant types are not subject to ownership.
Anonymous access types create temporary **borrows** (mutable, via `access T`)
or **observers** (read-only, via `access constant T`) -- both are subject to
ownership rules.

### Observers and borrowers

**Observers** (`access constant T`): Read-only aliases. Multiple can coexist. The
owner retains read permission but loses write permission while observers exist.
When all observers leave scope, full permissions restore.

**Borrowers** (`access T`): Temporary mutable aliases. Only one at a time. The
owner loses **all** permissions while the borrower exists. When the borrower
leaves scope, the owner regains full permissions (reflecting any modifications).

This is the fundamental tradeoff: observers allow shared reading; borrowers allow
exclusive mutation. You cannot have both simultaneously.

### Reborrows go deeper

A borrower can narrow its scope deeper into a structure (`Y := Y.Next`). Each
reborrow freezes the parts of the structure above it at their current values.
Reborrows must go strictly **deeper** -- jumping to siblings or unrelated parts
is forbidden.

### The "At End" / pledge concept

Since the owner is inaccessible during a borrow, SPARK provides `At_End_Borrow`
functions to reason about what the owner will look like **after** the borrow ends.
These are ghost identity functions with a special annotation:

```ada
function At_End_Borrow (E : access constant List_Acc)
  return access constant List_Acc is (E)
with Ghost, Annotate => (GNATprove, At_End_Borrow);
```

`At_End_Borrow(X)` represents a "prophecy" -- the value X will have when the
borrow scope ends. At runtime it's the identity function. GNATprove proves
assertions hold for all possible borrower modifications.

After a reborrow, frozen parts have known values:

```ada
Y := Y.Next.Next;  -- reborrow
pragma Assert (At_End_Borrow(X).Val = 1);  -- frozen: known
```

Save prophecy values as ghost constants before a reborrow to preserve knowledge:

```ada
Z : constant access constant List := At_End_Borrow(Y) with Ghost;
Y := Y.Next;  -- second reborrow
pragma Assert (At_End_Borrow(X).Next.Val = Z.Val);
```

### No pointer equality, no `'Old` on pointers

GNATprove does not model pointer addresses. `X = Y` is only allowed when one
operand is `null`. Two pointers to equal values are not distinguished.

Pointer values cannot be captured by `'Old`. Use a ghost deep-copy function:

```ada
function Deep_Copy (X : Int_Acc) return Int_Acc is (new Integer'(X.all))
with Ghost;

procedure Swap (X, Y : in out Int_Acc) with
  Post => X.all = Deep_Copy(Y)'Old.all;
```

### Automatic leak checking

GNATprove automatically checks three leak conditions:
1. LHS of assignment doesn't leak (old value was null or transferred)
2. No leak at end of scope
3. Deallocated memory owns nothing nested (recursive free required)

## Patterns

### Linked list type

```ada
type List;
type List_Acc is access List;
type List is record
   Value : Element;
   Next  : List_Acc;
end record;
```

### Observer traversal

```ada
function Contains (L : access constant List; E : Element) return Boolean is
   C : access constant List := L;
begin
   while C /= null loop
      if C.Value = E then return True; end if;
      C := C.Next;
   end loop;
   return False;
end;
```

### Borrower traversal (in-place modification)

```ada
procedure Set_Nth (L : access List; N : Positive; E : Element) is
   X : access List := L;
   P : Positive := N;
begin
   while X /= null loop
      if P = 1 then X.Value := E; return; end if;
      X := X.Next;
      P := P - 1;
   end loop;
end;
```

### Borrowing traversal function (returns mutable reference)

```ada
function Tail (L : access List) return access List with
  Contract_Cases =>
    (L = null => Tail'Result = null and At_End_Borrow(L) = null,
     others   => At_End_Borrow(L).Val = L.Val
       and Eq(L.Next, Tail'Result)
       and Eq(At_End_Borrow(L).Next, At_End_Borrow(Tail'Result)));
```

### Recursive deallocation

```ada
procedure Free_List (L : in out List_Acc) with
  Depends => (L => null, null => L),
  Post    => L = null
is
   procedure Internal_Free is new Ada.Unchecked_Deallocation
     (Object => List, Name => List_Acc);
begin
   if L /= null then Free_List (L.Next); end if;
   Internal_Free (L);
end;
```

The `(null => L)` is what silences the warning about unused value; the
`(L => null)` part is required to complete the contract. See
[contracts.md § Dependency clauses](contracts.md).

### Ownership transfer (move)

```ada
Tmp := X;   -- move X -> Tmp (X now inaccessible)
X := Y;     -- move Y -> X (Y now inaccessible)
Y := Tmp;   -- move Tmp -> Y
```

### Loop invariant with pledges

```ada
while X /= null loop
   pragma Loop_Invariant (C = Length(X)'Loop_Entry - Length(X));
   pragma Loop_Invariant
     (Length(At_End_Borrow(L)) = C + Length(At_End_Borrow(X)));
   X.Val := 0;
   X := X.Next;
   C := C + 1;
end loop;
```

## Workflow

### When to use access types

Languages like C/C++/Rust require access types or explicit references to ensure
pass-by-reference and to allow a subprogram to modify a parameter. In Ada, it's
rare to force pass-by-reference; generally, we let the compiler make this choice.
Additionaly, in Ada, we always prefer to use `out` or `in out` parameters in
subprograms that want to modify parameters, avoiding this use of access types.

Prefer arrays and records when size is known or bounded. Use access types only
for genuinely dynamic, unbounded, or recursive structures. The ownership rules
add significant proof complexity.

### Proving access-type code

1. Define the recursive type and deallocation procedure
2. Write ghost model functions (`Length`, `Get`, `Eq`) mapping pointer structures
   to mathematical models for use in contracts
3. Write traversal functions (observing/borrowing) using the loop-with-reborrow pattern
4. Add `At_End_Borrow` functions for borrowing traversals needing postconditions
5. Loop invariants must track: (a) position/counter, (b) reconstruction relation
   via `At_End_Borrow`, (c) element-level properties

## Gotchas

- **Reading a moved variable is an error.** After `Y := X`, any access to `X` fails.
- **Reborrows must go deeper.** Cannot jump to siblings or unrelated parts.
- **No pointer equality** except against `null`.
- **No `'Old` on pointers.** Use ghost deep-copy functions.
- **Recursive deallocation required.** Freeing a node without freeing its children
  triggers a leak check failure.
- **`'Access` only in assignment/declaration/return** for ownership types.
- **No borrowing of slices.**
- **Procedures cannot move borrowed parameters.** An `in out` access parameter
  must return ownership; you cannot move it elsewhere and leave it dangling.

## References

- [Pointer Support, Ownership, and Dynamic Memory](https://docs.adacore.com/live/wave/spark2014/html/spark2014_ug/en/source/access.html) -- Moving, observing, borrowing, deallocation
- [Traversal Functions](https://docs.adacore.com/live/wave/spark2014/html/spark2014_ug/en/source/access.html#traversal-functions) -- Observing and borrowing traversal patterns
- [At_End_Borrow Annotation](https://docs.adacore.com/live/wave/spark2014/html/spark2014_ug/en/appendix/additional_annotate_pragmas.html#annotation-for-referring-to-a-value-at-the-end-of-a-local-borrow) -- Prophecy variables for borrow specs
- [Memory Ownership Policy](https://docs.adacore.com/live/wave/spark2014/html/spark2014_ug/en/spark_2014.html#memory-ownership-policy) -- Rules preventing aliasing via ownership
