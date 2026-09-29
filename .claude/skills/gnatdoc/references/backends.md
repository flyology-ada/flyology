# GNATdoc Backends

`gnatdoc` ships with the following output backends, selected via
`--backend`:

| Backend | `--backend` value | Output |
|---------|-------------------|--------|
| HTML (default) | `html` | A set of HTML files browseable in any web browser. Pass the separate `--html-oop-style` switch to group subprograms by tagged type. |
| OpenDocument | `odf` | A single OpenDocument Text (`.fodt`) file |
| reStructuredText | `rst` | `.rst` files for Sphinx with an Ada-domain extension |
| RST (pass-through) | `rstpt` | Advanced/source-only variant — see § [RST pass-through](#rst-pass-through-rstpt) below. Always produces OOP-style output. |
| XML | `xml` | An XML dump, intended for downstream tooling |

The resources directory used to customize each backend's output lives at
`<install_dir>/share/gnatdoc/<backend>/`; copy those files to your
project's `Documentation'Resources_Dir` (see
[project-setup.md](project-setup.md)) and modify them to override the
defaults.

## HTML

The default backend.

```bash
gnatdoc -P project.gpr               # equivalent to --backend=html
gnatdoc --backend=html -P project.gpr
```

### Layout modes

By default, generated entities are grouped by compilation unit.

Pass the HTML-backend-only `--html-oop-style` switch to enable OOP-style
grouping — subprograms are grouped by tagged type, with one page per
tagged type:

```bash
gnatdoc --backend=html --html-oop-style -P project.gpr
```

OOP mode is appropriate for object-oriented Ada codebases where readers
expect a class-like view of behavior; the default per-unit mode tracks
the source file structure more closely.

**Note on older syntax.** Earlier GNATdoc releases exposed this as
`--backend=html:oop`. The current tool rejects that form with
`unknown backend`; use the separate `--html-oop-style` switch. The RST
backend has an analogous `--rst-oop-style` switch.

### Resources directory layout

When customizing the HTML backend, `Documentation'Resources_Dir
("html")` (or the per-backend subdirectory of an unqualified
`Resources_Dir`) must follow this layout:

```
<resources_dir>/
├── static/                         (copied verbatim into the output)
│   ├── css, images, etc.
└── template/                       (XHTML templates — singular "template")
    ├── index.xhtml                 (home page)
    ├── unit.xhtml                  (one compilation unit)
    ├── class.xhtml                 (OOP-mode class page; only relevant when --html-oop-style is in use)
    ├── overview.xhtml.ent          (fragment included by the page templates)
    └── toc.xhtml.ent               (fragment included by the page templates)
```

`static/` is the place for CSS, additional images, fonts, JavaScript —
anything that should be copied into the output directory unchanged.

**Note on the directory name.** It is `template/` (singular), matching
the bundled resources at `<install_dir>/share/gnatdoc/html/template/`.
A `templates/` (plural) override directory will not be picked up.

## ODF

Generates an OpenDocument Text document — viewable in LibreOffice
Writer, Microsoft Word, and other office suites. Useful for distributing
reference documentation as a single file or for printing.

```bash
gnatdoc --backend=odf -P project.gpr
```

Output can be customized by overriding
`<resources_dir>/template/documentation.fodt`.

The ODF backend is the most sensitive to image-sizing — supply explicit
widths/heights in your Markdown image references (see the syntax in
[annotations.md § Text markup](annotations.md#text-markup)), otherwise
images may render invisible or at the wrong scale.

## RST

Generates `.rst` files intended for processing by
[Sphinx](https://www.sphinx-doc.org/) configured with the `ada-domain`
extension.

```bash
gnatdoc --backend=rst -P project.gpr
```

Use this backend when you want `gnatdoc` output to integrate into an
existing Sphinx documentation site (e.g. as an API-reference section
alongside hand-written guides).

The RST backend supports an `--rst-oop-style` switch analogous to
`--html-oop-style`: pass it to group subprograms by tagged type.

## RST pass-through (`rstpt`)

A pass-through variant of the RST backend. Always produces OOP-style
output (non-OOP layout is not supported in pass-through mode); accepts
no backend-specific options.

```bash
gnatdoc --backend=rstpt -P project.gpr
```

The output is reStructuredText with `ada:` Sphinx directives, the same
markup family as `--backend=rst`. Confirm with your downstream Sphinx
setup which variant is the right consumer for it.

**Advanced / not in `--help`.** `gnatdoc --help` advertises only
`html|odf|rst|xml`; `rstpt` is accepted but is not part of the
documented public surface.

## XML

Generates an XML representation of the extracted documentation, intended
for downstream tooling rather than direct consumption.

```bash
gnatdoc --backend=xml -P project.gpr
```

Use this backend to feed `gnatdoc`'s extracted documentation into a
custom rendering pipeline (e.g. a static-site generator with a bespoke
template engine, or to merge with documentation generated for other
languages).
