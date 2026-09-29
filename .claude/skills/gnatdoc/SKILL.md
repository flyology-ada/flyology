---
name: gnatdoc
description: This skill should be used when the user wants to "generate API documentation", "generate Ada documentation", "run gnatdoc", "document an Ada package", "annotate Ada code with GNATdoc tags", "use @param/@return/@field/@enum/@exception/@exclude tags", "produce HTML/ODF/RST/XML docs for Ada code", or is otherwise working with GNATdoc to extract documentation from Ada sources.
license: Apache-2.0
metadata:
  version: "0.1.0"
  source_repository: "https://github.com/AdaCore/skills"
  source_revision: "ab0360b0adcb0c0831bc2836aaa4d4bcfdc9cf74"
  modified_by: "flyology-ada/agents"
---

# GNATdoc Documentation Generation Skill

`gnatdoc` is AdaCore's documentation generator for Ada. It parses an Ada
project, extracts documentation comments from the source code (using a
cross-reference engine for accuracy), and emits an annotated HTML site
(default), an OpenDocument Format document, a set of reStructuredText files,
or an XML dump.

`gnatdoc` is *not* a free-form generator — it requires a GNAT project file
(`.gpr`) and reads only the comments at well-defined locations (preceding or
following declarations, depending on the configured style).

## Locating GNATdoc

Unless the user has already told you how to invoke `gnatdoc`, determine the
right invocation in this order:

1. **Check for an `alire.toml` in the project root.** Its presence means the
   project is an Alire crate. Invoke `gnatdoc` via
   `alr exec -- gnatdoc -P <project.gpr> ...` so Alire injects the correct
   environment (`GPR_PROJECT_PATH`, `PATH`, etc.) before the tool runs.

2. **Check if `gnatdoc` is already on `PATH`.** Run `which gnatdoc`. If
   found, use it — but if runs fail with project-file resolution errors, the
   environment may be incomplete (see step 3). `gnatdoc` ships as part of
   the GNAT Studio package, so it is typically installed alongside GNAT
   Studio's other binaries.

3. **Ask the user.** GNAT Pro and GNAT Studio installations (commonly under
   `/usr/gnat`, `/opt/gnat`, or a vendor-specific path) typically require
   environment setup beyond a binary on `PATH`. Don't guess — ask the user
   how they want to configure the environment.

## Quick Start

`gnatdoc` always requires a project file. The minimal invocation is:

```bash
gnatdoc -P <project.gpr>
```

This generates HTML documentation under `<obj>/gnatdoc/html/` (the default
output is `<obj>/gnatdoc/<backend-name>/`, where `<obj>` is the object
directory of the root project). Open `index.html` in that directory to view
the output.

A more complete invocation that names the backend explicitly, enables
undocumented-entity warnings, and tees the output for later inspection:

```bash
gnatdoc --backend=html --warnings -P <project.gpr> 2>&1 | tee gnatdoc-run.txt
```

Common arguments:

| Flag | Effect |
|------|--------|
| `-P, --project FILE` | Project file. **Required**. |
| `--backend=<html\|odf\|rst\|rstpt\|xml>` | Output format. Default `html`. See [references/backends.md](references/backends.md). |
| `--html-oop-style` | (HTML backend only) Group subprograms by tagged type, generating a separate page for each tagged type. Replaces the older `--backend=html:oop` syntax. |
| `--generate=<public\|private\|body>` | Which entities to document. `public` (default) = public part of specs; `private` = public + private spec; `body` = specs + library-level body entities. See [references/command-reference.md](references/command-reference.md#generate). |
| `--style=<leading\|trailing\|gnat>` | Where documentation comments sit relative to declarations. Default `gnat`; `trailing` and `gnat` are equivalent. See [references/styles.md](references/styles.md). |
| `-O, --output-dir DIR` | Override the output directory. Overrides `Documentation'Output_Dir` in the project file. |
| `-X NAME=VALUE` | Set a scenario variable on the project. Repeatable. |
| `--warnings` | Emit warnings for every undocumented entity — subprograms, parameters, return values, components, discriminants, enumeration literals, generic formals, raised exceptions. Informational only; it never changes the generated output. See [Verifying a run](#verifying-a-run) for how to act on the list. |
| `-v, --verbose` | Verbose output. |
| `--version` | Print the GNATdoc version and exit. Useful for diagnosing behavior differences across builds. |
| `--print-gpr-registry` | Print the supported `Documentation` package GPR attributes and exit. |
| `-h, --help` | Help. |

## Verifying a run

A zero exit code from `gnatdoc` does not mean the documentation is
complete or correct. After every run, check at least these:

1. **The output directory exists.** Default is `<obj>/gnatdoc/<backend>/`
   (e.g. `<obj>/gnatdoc/html/`). If you passed `-O` or set
   `Documentation'Output_Dir`, look there instead.
2. **The entry-point file is present.** For HTML that is `index.html`
   inside the output directory; for ODF, the `.fodt` file; for RST, the
   set of `.rst` files; for XML, the produced `.xml` file.
3. **The captured log (`gnatdoc-run.txt` if you teed) has no error lines
   and the expected warning lines.** Search for `warning:` and `error:` —
   `--warnings` reports undocumented entities here. Treat that list as a
   coverage report, not a to-do list: address warnings for entities you
   added or modified, but leave pre-existing warnings alone unless the
   user has asked for a wider documentation campaign — report them to
   the user instead.
4. **Open the entry-point file.** Spot-check that the units you expect
   are present and the doc comments rendered as intended. A blank line or
   wrong indentation silently disassociates a comment from its entity:
   with `--warnings` the entity is then reported as "not documented", but
   nothing ever points at the stray comment itself.

## Mandatory pre-work

Before running `gnatdoc` on a new project, do these in order:

1. **Make sure the project builds with the standard toolchain.** Use the
   same invocation environment as the one you'll use for `gnatdoc` itself
   — `alr exec -- gprbuild -P <project.gpr>` for Alire crates, plain
   `gprbuild -P <project.gpr>` otherwise. `gnatdoc` parses sources as GNAT
   sees them; an unbuildable project will not be processable, and an
   environment mismatch between `gprbuild` and `gnatdoc` will mask the
   real issue.

2. **Determine the documentation style.** `--style=leading`,
   `--style=trailing`, and `--style=gnat` change *where* `gnatdoc` looks
   for the comment block attached to each declaration; mixing styles
   within a project leads to silently dropped documentation. If the user
   or the existing build scripts specify a style, use it. Otherwise
   survey the sources to match the existing convention, and ask the user
   only if the survey is inconclusive. See
   [references/styles.md § Determining a project's existing style](references/styles.md#determining-a-projects-existing-style).
   Record the choice in the build script that invokes `gnatdoc` — no
   project-file attribute exists for the style.

3. **Agree on the documentation scope.** Ask the user which entities to
   document: `--generate=public` (public spec only — the default),
   `--generate=private` (public + private spec), or `--generate=body`
   (also library-level body entities). If they express no preference,
   use the default `public`. See
   [references/command-reference.md § generate](references/command-reference.md#generate).

## Core principles

- **A `.gpr` project file is mandatory.** `gnatdoc` cannot operate on loose
  source files.

- **Default output is transient.** Without `Documentation'Output_Dir` (or
  `-O`), output lands under the object directory, where it is typically
  gitignored and deleted by `gprclean`. For documentation you want to
  commit or publish, set `Output_Dir` to a path outside `obj/`, or pass
  `-O <path>`. See [references/project-setup.md](references/project-setup.md).

- **Comments must be adjacent to the declaration.** A blank line between
  the doc block and the declaration breaks the association. Keep doc
  comments tight against the entity they describe.

- **`gnatdoc` skips externally-built projects.** Recursive processing
  walks the full dependency graph *except* externally-built projects
  (typically prebuilt third-party libraries). To exclude additional
  projects, use `Documentation'Excluded_Project_Files`. See
  [references/project-setup.md](references/project-setup.md).

## Reference files

| Topic | File | When to read |
|-------|------|-------------|
| CLI switches and their semantics | [command-reference.md](references/command-reference.md) | Looking up any `gnatdoc` flag or its effect |
| Documentation tags (`@param`, `@return`, `@field`, `@enum`, `@exception`, `@exclude`, …) and where comment blocks attach | [annotations.md](references/annotations.md) | Writing or fixing documentation comments in Ada sources |
| `leading` vs. `trailing` vs. `gnat` styles | [styles.md](references/styles.md) | Determining an existing project's style, choosing one for a new project, or migrating |
| `Documentation` package attributes in `.gpr` (`Documentation_Pattern`, `Excluded_Project_Files`, `Output_Dir`, `Resources_Dir`, `Image_Dirs`) | [project-setup.md](references/project-setup.md) | Configuring `gnatdoc` declaratively in the project file |
| Backends (HTML, ODF, RST, XML), OOP layout switches (`--html-oop-style`, `--rst-oop-style`), resource directory layouts | [backends.md](references/backends.md) | Picking an output format or customizing rendering |
