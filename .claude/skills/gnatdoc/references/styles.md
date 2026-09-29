# Documentation Comment Styles

`gnatdoc` supports two effective documentation styles, surfaced as three
spellings on the `--style` switch:

| Style spelling | Doc comment location | Notes |
|----------------|----------------------|-------|
| `leading`  | Comment block immediately **precedes** the entity declaration | "Doxygen-like" placement. Distinct internal style. |
| `trailing` | Comment block immediately **follows** the entity declaration | **Same internal style as `gnat`** — the two spellings are equivalent. |
| `gnat`     | Comment block immediately **follows** the entity declaration | Default. Matches the convention used in the GNAT runtime sources. |

Internally `gnatdoc` has only two documentation styles, `GNAT` and
`Leading`. The command-line parser accepts `--style=trailing` and
`--style=gnat` as separate spellings, but both select the `GNAT` style
— there is no observable difference in extraction between them.

In all styles, the documentation comment block must **not** be separated
from the declaration by an empty line, and must share the declaration's
indentation. Inline comments at deeper indentation are interpreted as
documentation of nested elements (parameters, components, enumeration
literals).

## Picking a style

Pick one per project and keep to it — mixing styles within one
invocation causes one half of the comments to be silently ignored.

- **`gnat`** (or equivalently `trailing`) is the right default for
  projects that follow AdaCore's own conventions (GNAT runtime,
  AdaCore-published crates). Documentation reads naturally after the
  declaration. This is the default if `--style` is omitted.
- **`leading`** is the right default for teams coming from C/C++/Java
  with Doxygen/Javadoc habits; doc comments live "above" each
  declaration.

There is no third option. `trailing` and `gnat` differ only in spelling.
Prefer whichever name reads more clearly in your build scripts —
`--style=gnat` is the convention in AdaCore tooling.

Record the choice somewhere durable — in the build script that calls
`gnatdoc`, or in a `Documentation` package attribute (no dedicated
attribute exists for the style itself, so most teams pass `--style` on
the command line).

## Determining a project's existing style

For an existing codebase, match the convention already in place rather
than choosing one:

1. **Check the build scripts and CI configuration** for an existing
   `--style` switch on a `gnatdoc` invocation.
2. **Survey the sources.** Read a few documented package specs and check
   whether doc blocks sit above declarations (`leading`) or below them
   (`trailing`/`gnat`).
3. **Cross-check empirically** if unsure: run `gnatdoc --warnings` once
   with the default `gnat` style and once with `--style=leading`, and
   compare the number of "not documented" warnings — the correct style
   produces far fewer.

If the results are inconclusive — comment placement is mixed, or the
project has no documentation yet — ask the user which convention to
adopt rather than picking one silently.

## `gnat` (trailing) style — example

The documentation for composite entities (records, enumerations,
subprograms) describes the entity in its main block, *after* the
declaration, and may include per-element inline documentation:

```ada
package Style_GNAT_Composite is

   type Enumeration_Type is
     (Item_1,  --  Enumeration literal's description at the declaration line
      Item_2,
      --  Enumeration literal's description below declaration line
      Item_3);
   --  Enumeration type has description of the type and description of
   --  individual enumeration literals.
   --
   --  @enum Item_3 Enumeration literal's description using GNATdoc's tag in
   --  the documentation of the enumeration type.

   type Record_Type is record
      Component_1 : Integer;  --  Record component's description at the
                              --  declaration line.
      Component_2 : Integer;
      --  Record component's description below the line of declaration.
      Component_3 : Integer;
   end record;
   --  Record type has description of the type and description of individual
   --  components.
   --
   --  @field Component_3 Record component's description using GNATdoc's tag
   --  in the documentation of the record type.

   procedure Do_Something
     (X : Integer;  --  Subprogram parameter's description at the line of
                    --  declaration.
      Y : Integer;
      --  Subprogram parameter's description below declaration line
      Z : Integer);
   --  All subprograms, including procedures, have a description of the
   --  subprogram, descriptions of parameters, and descriptions of raised
   --  exceptions.
   --
   --  @param Z Subprogram parameter's description using GNATdoc's tag in the
   --  documentation of the subprogram.
   --  @exception Constraint_Error Description of conditions under which an
   --  exception can be raised by the subprogram.

   function Compute_Something_1 (X : Integer) return Integer;
   --  In addition to procedures, a function has a description of the return
   --  value.
   --
   --  @return Description of return value of the function with GNATdoc's tag.

   function Compute_Something_2
     return Integer;  --  Description of the return value at the line of
                      --  `return`.
   --  Just another way to describe a return value.

end Style_GNAT_Composite;
```

## `leading` style — same content, doc above each declaration

Note that the style moves the *entity-level* block above the declaration;
*element-level* comments (parameters, components, literals) may still sit
on the element's own line or on the line immediately below it, exactly as
in the `gnat` style — as the labels in this example show:

```ada
package Style_Leading_Composite is

   --  Enumeration type has description of the type and description of
   --  individual enumeration literals.
   --
   --  @enum Item_3 Enumeration literal's description using GNATdoc's tag in
   --  the documentation of the enumeration type.
   type Enumeration_Type is
     (Item_1,  --  Enumeration literal's description at the declaration line
      --  Enumeration literal's description below declaration line
      Item_2,
      Item_3);

   --  Record type has description of the type and description of individual
   --  components.
   --
   --  @field Component_3 Record component's description using GNATdoc's tag
   --  in the documentation of the record type.
   type Record_Type is record
      Component_1 : Integer;  --  Record component's description.
      --  Record component's description below the line of declaration.
      Component_2 : Integer;
      Component_3 : Integer;
   end record;

   --  All subprograms, including procedures, have a description of the
   --  subprogram, descriptions of parameters, and descriptions of raised
   --  exceptions.
   --
   --  @param Z Subprogram parameter's description using GNATdoc's tag in the
   --  documentation of the subprogram.
   --  @exception Constraint_Error Description of conditions under which an
   --  exception can be raised by the subprogram.
   procedure Do_Something
     (X : Integer;  --  Subprogram parameter's description at the line.
      --  Subprogram parameter's description below declaration line.
      Y : Integer;
      Z : Integer);

   --  In addition to procedures, a function has a description of the return
   --  value.
   --
   --  @return Description of return value of the function with GNATdoc's tag.
   function Compute_Something_1 (X : Integer) return Integer;

   --  Just another way to describe a return value.
   function Compute_Something_2
     return Integer;  --  Description of the return value at the line of
                      --  `return`.

end Style_Leading_Composite;
```

## Migrating between styles

There is no automated migration. To move an existing project from
`leading` to `gnat` (or vice versa):

1. Audit which style the existing comments use. A mixed codebase produces
   misleading `--warnings` output until it is normalized.
2. Switch the doc blocks one package at a time, running
   `gnatdoc --warnings` after each batch to confirm no documentation was
   lost.
3. Update the build command (or `Documentation` package) to record the
   new default.
