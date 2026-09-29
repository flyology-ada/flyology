<!-- Modified by flyology-ada/agents: normalized the final newline. -->

# Dynamic Accessibility Check in a Traversal Function

A `dynamic accessibility check might fail` on a function that returns an
anonymous `access` result derived from one of its parameters (a *traversal
function* — the basis of `Reference` / `Constant_Reference`-style borrows and
observes) means the prover cannot *statically* bound the accessibility level of
the returned access.

If `'Access` is used, the accessibility of the anonymous-access result is pinned
to its prefix object. It stays statically known — and the check is discharged —
only when one of these holds:

- it is a subcomponent of the value designated by an object of a **named**
  access type (named access types carry a static accessibility level), or
- the prefix of `'Access` is **a part of the traversed parameter** — i.e. you
  reach the borrowed object directly through the parameter, with no
  intermediate local access object in between.

The usual cause is an **intermediate local access variable**. Binding the
borrowed reference to a local anonymous-access object introduces a *fresh,
function-local* accessibility level; taking `'Access` of a component of that
local object then has a dynamic level the caller's master cannot be shown to
outlive:

```ada
function Reference (P : in out Handle) return not null access Element is
   --  Raw_Reference (P) borrows P; Convert reinterprets the cell.
   Local : access Cell := Convert (Raw_Reference (P));  --  local anon access
begin
   return Local.Value'Access;   --  prefix is part of a *local* object
                                 --  → dynamic accessibility check fails
end Reference;
```

**Fix — inline the borrow into the `return`** so the `'Access` prefix is
reached directly through the traversed parameter, with no local object to
relevel:

```ada
function Reference (P : in out Handle) return not null access Element is
begin
   return Convert (Raw_Reference (P)).Value'Access;
   --  prefix reaches the borrowed object straight through P; accessibility
   --  stays static and the check is discharged.
end Reference;
```
