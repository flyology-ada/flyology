# GNATdoc Command Reference

```
gnatdoc [options] project_file
```

A project file is required: pass it positionally or with `-P`. There is no
standalone file mode.

## Switches

### `-P, --project=<file>`

Specify the path name of the main project file. The space between `-P` and
the project file name is optional.

Equivalent forms:

```bash
gnatdoc -P myproject.gpr
gnatdoc --project=myproject.gpr
gnatdoc myproject.gpr
```

### `-X NAME=VALUE`

Specify an external reference for project scenario variables. May be passed
multiple times to set several scenario variables on the same invocation:

```bash
gnatdoc -P myproject.gpr -X BUILD=Debug -X TARGET=arm-elf
```

### `--backend=<html|odf|rst|rstpt|xml>` <a id="backend"></a>

Select the output format. Default is `html`.

| Value   | Description |
|---------|-------------|
| `html`  | Generate annotated HTML. Default backend. To group subprograms by tagged type (one page per tagged type) rather than per compilation unit, pass the separate `--html-oop-style` switch — see below. |
| `odf`   | Generate an OpenDocument Format document. Suitable for opening in Microsoft Word, LibreOffice Writer, etc. |
| `rst`   | Generate reStructuredText files. Intended to be processed by Sphinx with an Ada-domain extension. |
| `rstpt` | Pass-through RST variant. Always produces OOP-style output; takes no backend-specific options. **Advanced** — accepted but not advertised in `--help`. See [backends.md § RST pass-through](backends.md#rst-pass-through-rstpt). |
| `xml`   | Generate XML, intended for downstream tooling. |

See [backends.md](backends.md) for backend-specific details and resource
directory layouts.

### `--html-oop-style`

HTML-backend-only option. Groups subprograms by tagged type, generating a
separate page for each tagged type. Without this switch, entities are
grouped by compilation unit.

```bash
gnatdoc --backend=html --html-oop-style -P project.gpr
```

**Note:** older GNATdoc versions exposed this as a suffix on the backend
name (`--backend=html:oop`). The current tool rejects that form with
`unknown backend`; pass `--html-oop-style` as a separate switch instead.

### `--generate=<public|private|body>` <a id="generate"></a>

Select which entities documentation is generated for.

| Value | Scope |
|-------|-------|
| `public`  | Entities declared in the public part of the package specification. **Default.** |
| `private` | Entities declared in the package specifications, in both public *and* private parts. |
| `body`    | All entities declared in the package specifications *and* at library level in package bodies. **NOT RECOMMENDED** |

### `--style=<leading|trailing|gnat>`

Select the documentation comment style. Determines where `gnatdoc` looks for
comment blocks relative to a declaration.

| Value | Where the comment lives |
|-------|------------------------|
| `leading`  | Comment block *precedes* the entity declaration. |
| `trailing` | Comment block *follows* the entity declaration. **Equivalent to `gnat`** — both map to the same internal style. |
| `gnat`     | Same as `trailing`. The default if `--style` is not given. |

`trailing` and `gnat` are accepted as separate spellings but the tool treats
them identically. See [styles.md](styles.md) for examples and the rationale.

### `-O, --output-dir=<output_dir>`

Override the output directory for generated documentation. Overrides the
value of the `Documentation'Output_Dir` attribute defined in the project
file.

```bash
gnatdoc -P myproject.gpr -O docs/api
```

### `--warnings`

Emit a warning for every entity with an empty description: subprograms,
parameters, return values, record components, discriminants, enumeration
literals, generic formals, and raised exceptions. Use during
documentation campaigns to find undocumented entities.

### `-v, --verbose`

Enable verbose output (progress and diagnostic information).

### `--version`

Print the GNATdoc version and exit. Useful for diagnosing behavior
differences across builds — for instance, deciding whether to use
`--html-oop-style` (current) versus `--backend=html:oop` (older).

### `--print-gpr-registry`

Print the list of GPR `Documentation` package attributes that this build
of GNATdoc recognizes (and the GPR attribute schema), then exit. Useful
when configuring a project file declaratively to confirm the attribute
names and their indexing.

### `-h, --help`

Display help information and exit.

## Default behavior

If no options are given (other than `-P`), `gnatdoc`:

- Uses the **HTML** backend.
- Generates documentation only for **public** specifications
  (`--generate=public`).
- Writes output under `<obj>/gnatdoc/<backend>/` — e.g.
  `<obj>/gnatdoc/html/` for the default HTML backend — where `<obj>` is
  the object directory of the root project.
- Recursively processes the projects on which the root project depends —
  *except* externally-built projects, which are unconditionally excluded.
  Additional projects can be excluded via the
  `Documentation'Excluded_Project_Files` attribute. See
  [project-setup.md](project-setup.md).
