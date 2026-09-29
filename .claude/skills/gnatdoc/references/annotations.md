# Annotating Ada Source Files for GNATdoc

`gnatdoc` extracts documentation directly from comments in your Ada
sources. *Special tags* (`@param`, `@return`, `@field`, `@enum`,
`@exception`, `@formal`, `@exclude`, and their aliases) refine which part
of the comment block applies to which sub-entity.

The comment block must be **adjacent** to the declaration (no blank line
between them) and have the **same indentation** as the declaration (so
`gnatdoc` can distinguish it from inline documentation of nested elements
like parameters or components).

The set of locations `gnatdoc` searches for the comment block depends on
the entity kind and the documentation style (`leading`, `trailing`, or
`gnat`). See [styles.md](styles.md) for the rules; the examples below
mostly use `trailing`/`gnat` (the default GNAT convention).

(The extractor also recognizes an undocumented `@belongs-to` tag, which
attaches an entity's documentation to another entity; it is not part of
GNATdoc's documented surface — avoid relying on it.)

## Packages

The comment block attached to a package is whichever of these is present:

* Directly preceding any context clauses
* Directly preceding the package declaration
* Directly following the `is` keyword of the package declaration
* Directly following the block of `pragma` directives and `use` context
  clauses at the beginning of the package declaration

Example:

```ada
--  Copyright (C) COPYRIGHT HOLDER

--  This package provides routines for drawing basic shapes and Bézier curves.

package Drawing is
```

## Enumeration types

The doc block is directly preceding or directly following the enumeration
type declaration, with the *same indentation* as the type — so `gnatdoc`
can distinguish it from per-literal inline documentation.

Use `@enum` to document individual enumeration literals from within the
type's main comment block:

```
@enum <enumeration_literal> <description>
```

Example:

```ada
--  Colors supported by this drawing application
--  @enum Black The black color is the default color of the pen
--  @enum White The white color is the default color of the background
--  @enum Green The green color is the default color of the border
type Colors is (Black, White, Green);
```

Inline alternative — document each literal on or under its own line; the
`@enum` tag is then not required:

```ada
--  Colors supported by this drawing application
type Colors is (
  Black,
  -- The black color is the default color of the pen
  White,
  -- The white color is the default color of the background
  Green);
  -- The green color is the default color of the border
```

The two forms can be combined — a general description in the main block
plus per-literal inline comments.

## Record types

The comment block is directly preceding or directly following the record
type declaration, at the same indentation, following the convention of your
selected style (`leading`, `trailing` or `gnat`). Components and discriminants
are documented either inline or via tags inside the type's main block:

```
@field <name> <description>
```

`@field` documents a record component *or* a discriminant. Three related
tags exist: `@comp` (components only), `@disc` (discriminants — also of
task and protected types), and `@member` (alias of `@field`).

Example (with `@field`):

```ada
--  A point representing a location in integer precision.
--  @field X Horizontal coordinate
--  @field Y Vertical coordinate
type Point is
 record
    X : Integer;
    Y : Integer;
 end record;
```

Inline alternative — document each component on or under its declaration;
no `@field` tag needed:

```ada
--  A point representing a location in integer precision.
type Point is
 record
    X : Integer;
    --  Horizontal coordinate
    Y : Integer;
    --  Vertical coordinate
 end record;
```

The forms can be combined (general type description in the main block,
per-component inline comments below each declaration).

## Subprograms

The doc block follows the subprogram declaration (`trailing`/`gnat`
style) or precedes it (`leading` style).

Supported tags:

### `@param`

```
@param <param_name> <description>
```

Documents one subprogram parameter. `<param_name>` must match the
parameter as it appears in the declaration.

### `@return`

```
@return <description>
```

Documents the return value of a function.

### `@exception`

```
@exception <exception_name> <description>
```

Documents an exception that the subprogram may raise. `<exception_name>`
is the name of the exception. `@raise` is an accepted alias.

Example (block form):

```ada
function Set_Alarm
  (Message : String;
   Minutes : Natural) return Boolean;
--  Display a message after the given time.
--  @param Message The text to display
--  @param Minutes The number of minutes to wait
--  @exception System.Assertions.Assert_Failure raised
--     if Minutes = 0 or Minutes > 300
--  @return True iff the alarm was successfully registered
```

Inline alternative — document each parameter on or under its own line and
the return type at the `return` line; no `@param`/`@return` tag required
for those:

```ada
function Set_Alarm
  (Message : String;
   --  The text to display
   Minutes : Natural)
   --  The number of minutes to wait
   return Boolean;
   --  Returns True iff the alarm was successfully registered
--  Display a message after the given time.
--  @exception System.Assertions.Assert_Failure raised
--     if Minutes = 0 or Minutes > 300
```

Combined forms (some parameters inline, some via `@param`) are supported.

## Generic formals — `@formal`

```
@formal <formal_name> <description>
```

Documents a generic formal parameter from the generic unit's main comment
block. Undocumented generic formals are reported by `--warnings`.

## Excluding entities — `@exclude`

The `@exclude` tag tells `gnatdoc` to *omit* the entity from the
generated documentation. Useful for declarations that are public in Ada
terms but logically internal:

```ada
type Calculator is tagged ...
procedure Add (Obj : Calculator; Value : Natural);
--  Addition of a value to the previous result
--  @param Obj The actual calculator
--  @param Value The added value
procedure Dump_State (Obj : Calculator);
--  @exclude No information is generated in the output about this
--  primitive because it is internally used for debugging.
```

**Notes:**

- `@private` is an alias of `@exclude` and is no longer recommended.
- Specifying `@exclude` on a *package* removes the package **and all its
  child packages** from the generated documentation.

The related `@exclude-value` tag keeps the entity in the documentation
but suppresses the rendering of its value — useful for constants whose
value is an implementation detail:

```ada
C : constant Integer := 5;
--  The constant and its description are documented, but the value 5
--  does not appear in the output.
--  @exclude-value
```

## Text markup

Inside any description, `gnatdoc` recognizes a [CommonMark
MarkDown](https://commonmark.org/)-based subset:

* paragraphs
* lists (ordered and unordered) and list items
* indented code blocks (three or more leading spaces)
* `*emphasis*` / `**strong emphasis**`
* `` `code spans` ``
* images (`![alt](path)` — see `Image_Dirs` in
  [project-setup.md](project-setup.md))

Some backends require image sizes to be specified explicitly:

```
![Ada Inside](ada_logo_64x64.png){width=14pt height=14pt}
```

Without explicit sizing, an image may appear invisible or at the wrong
scale on backends that need it (notably ODF).

## Common pitfalls

- **Blank line between the doc block and the declaration.** The
  association is silently broken; the comment is treated as freestanding
  and dropped. `--warnings` then reports the entity as *not documented*,
  but nothing ever points at the disassociated comment itself.

- **Wrong indentation.** A doc block intended for the type but indented
  with the component will be attached to the component (or dropped). The
  rule: same indentation as the entity the doc describes.

- **Mixing styles.** A project run with `--style=trailing` will silently
  ignore leading-style comments (and vice versa). Pick one style per
  project; see [styles.md](styles.md).

- **Tag name mismatches.** `@param Foo ...` where the parameter is
  actually `Bar` will not be associated with `Bar`. Tags resolve by
  exact name.
