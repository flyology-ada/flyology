<!-- Modified by flyology-ada/agents: normalized trailing whitespace. -->

# `type is unsuitable as a source for unchecked conversion` (unused bits)

GNATprove models each `Ada.Unchecked_Conversion` instance as a *function*: the
same input must always give the same result. For that to hold, the **source**
type must have no *unused bits* — bits whose value could differ between two
otherwise-equal values. A `high` check

```
type is unsuitable as a source for unchecked conversion
  [possible explanation: type "T" might have unused bits that are not modelled in SPARK]
```

means GNATprove cannot show the source type is gap-less.

Per the SPARK RM, a subtype is *suitable as the source of an unchecked
conversion* when it is compatible with unchecked conversion (not tagged / access /
immutably limited / unsuitable-private) and, **if composite, its `Size` equals
the sum of its components' `Size`s, and every component is itself suitable as a
source.** "Sum of component sizes" is the operative phrase: any padding the
compiler is free to insert breaks it.

Two recurring causes, both with solutions that resolve the check message:

## 1. Layout unknown to GNATprove

**Problem**: The type carries no representation clause, so GNATprove cannot
confirm `Size` = sum of components and conservatively assumes unused bits.
(Frequently paired with `warning: data representation info unavailable for
<file>`.)

**Fix**: Provide a **confirming `Object_Size` (and `Size`)**:

```ada
type Pair is record
   First, Second : Interfaces.Unsigned_8;
end record
with Object_Size => 16, Size => 16;
```

This applies whether the composite is the conversion's source directly or is a
*component* of the converted type.

## 2. Array component with non-static bounds

**Problem**: SPARK only sees that an array is gap-less when its **components are
`aliased`** *and* its **bounds are known at compile time**. Inside a generic, an
array whose length depends on a formal type's `'Size` / `'Object_Size` has bounds
that are *not* compile-time-known, so the enclosing record is flagged.

**Fix**: pass the
size as an **extra generic parameter** and build the array bound from it.
Because aliased components must be addressable, pad in **bytes**, not bits
(`'Object_Size` is a multiple of 8):

```ada
generic
   type Element_Type is private;
   Element_Object_Size : Positive;   --  must equal Element_Type'Object_Size
package P is
   pragma Compile_Time_Error
     (Element_Object_Size /= Element_Type'Object_Size, "...");
   pragma Compile_Time_Error
     (Element_Type'Object_Size mod 8 /= 0, "...");
   ...
private
   type Byte    is mod 2 ** 8 with Size => 8;
   type Padding is array (Positive range <>) of aliased Byte;   --  aliased!
   type Cell is record
      Value : aliased Element_Type;
      Pad   : Padding (1 .. (32 - Element_Object_Size) / 8);     --  bound from the formal
   end record;
```
