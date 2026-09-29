# Project File Setup for GNATdoc

`gnatdoc` configuration lives in the `Documentation` package of the
**root** project file. Attributes set in subprojects are ignored — only
the root project is consulted.

```ada
project My_Project is
   ...
   package Documentation is
      for Output_Dir use "docs";
      for Documentation_Pattern use "^<";
      for Excluded_Project_Files use ("vss_config.gpr", "vss_gnat.gpr");
      for Image_Dirs ("html") use ("images");
      for Resources_Dir ("html") use "docs/gnatdoc_html";
   end Documentation;
end My_Project;
```

## Attributes

### `Documentation_Pattern`

A regular expression matched against comment lines to decide which are
documentation. The expression matches the part of the line **after** the
leading `--`. Text up to and including the match is removed from the
documentation line.

```ada
package Documentation is
   for Documentation_Pattern use "^<";
   --  Only comments beginning with "--<" are treated as documentation.
   --  The leading "<" is stripped from the documentation text.
end Documentation;
```

If not set, **every** comment is treated as documentation. This is the
default and is appropriate for most projects that use ordinary `--`
comments only for documentation.

### `Excluded_Project_Files`

A list of project files to skip when generating documentation.

```ada
package Documentation is
   for Excluded_Project_Files use
     ("vss_config.gpr",
      "vss_gnat.gpr");
end Documentation;
```

The list may include any projects directly or transitively used by the
root project. Externally-built library projects are excluded
*unconditionally* — listing them here is unnecessary.

### `Output_Dir`

Output directory for the generated documentation.

There are two forms:

- **Unqualified** — applies to all backends; documentation is placed in
  a backend-named subdirectory under the given path:
  ```ada
  for Output_Dir use "docs";
  --  HTML output lands in "docs/html/", RST in "docs/rst/", etc.
  ```

- **Qualified by backend name** — applies to that backend only and is the
  directory that the backend writes into directly:
  ```ada
  for Output_Dir ("html") use "html";
  --  HTML output lands directly in "html/" (no subdirectory).
  ```

`-O`/`--output-dir` on the command line overrides whatever this attribute
sets.

**Default:** if neither the attribute nor `-O` is set, output is written
to `<obj>/gnatdoc/<backend>/` — e.g. `<obj>/gnatdoc/html/` for the
default HTML backend — where `<obj>` is the object directory of the
root project. If `obj/` is gitignored, that output is not
version-controlled and `gprclean` will delete it — set `Output_Dir` to
a path outside `obj/` for documentation that should be committed or
published.

### `Resources_Dir`

Path to a directory containing user-supplied static resources and
templates to override the backend defaults. Each backend ships with its
own resources under `<install_dir>/share/gnatdoc/<backend>/`; copy and
modify those to customize layout.

Two forms:

- Unqualified — a parent directory containing per-backend subdirectories:
  ```ada
  for Resources_Dir use "docs/gnatdoc";
  --  HTML reads from "docs/gnatdoc/html/", ODF from "docs/gnatdoc/odf/", etc.
  ```

- Qualified by backend name — the directory the named backend reads from
  directly:
  ```ada
  for Resources_Dir ("html") use "docs/gnatdoc_html";
  ```

Each backend defines its own layout inside this directory — see
[backends.md](backends.md).

### `Image_Dirs`

List of directories searched for images referenced from the
documentation (e.g. `![Alt](logo.png)`).

```ada
package Documentation is
   for Image_Dirs ("odf") use ("images");
end Documentation;
```

Paths are resolved relative to the directory of the root project file.

Like `Output_Dir` and `Resources_Dir`, this attribute may be qualified by
backend name — different backends may require images in different forms,
so a per-backend list is common.

## Subprojects

By default, `gnatdoc` walks the full project dependency graph and
generates documentation for every project, **except**:

- externally-built projects (always excluded), and
- projects listed in `Documentation'Excluded_Project_Files`.

To document the root project alone, list every dependency in
`Excluded_Project_Files`.

## Suggested baseline

For a typical Alire/GNAT project that wants version-controlled
documentation under `docs/`:

```ada
project My_Project is
   ...
   for Object_Dir use "obj";

   package Documentation is
      --  Land HTML output directly in docs/api/, not under obj/
      for Output_Dir ("html") use "docs/api";

      --  Optional: only treat "--!"-prefixed comments as documentation
      --  for Documentation_Pattern use "^!";
   end Documentation;
end My_Project;
```

Run with:

```bash
gnatdoc --warnings -P my_project.gpr
```

The `--warnings` flag reports undocumented entities.
