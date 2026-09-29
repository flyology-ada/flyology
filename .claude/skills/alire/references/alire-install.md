# Installing Binary Crates

Use `alr install` for binary tools (e.g. `gnattest`) that should be available
system-wide rather than as a project dependency.

```bash
alr install <crate_name>
```

Show the current installation prefix and what's installed in it:

```bash
alr install --info
```

The default prefix is `$HOME/.alire`; binaries land in `$HOME/.alire/bin/`.
**This directory is not added to `PATH` automatically** — neither for the
shell nor for `alr exec`. To use installed binaries, either add
`$HOME/.alire/bin` to `PATH` or call them by absolute path.

Override the prefix with `--prefix`:

```bash
alr install --prefix=<dir> <crate_name>
```

## `alr install` vs `alr with`

- `alr with <crate>` — adds a build-time dependency to the current crate's
  `alire.toml`. Use for **library** crates that the project links against
  (e.g. `aunit`).
- `alr install <crate>` — installs a release into a shared prefix, separate
  from any crate. Use for **binary tool** crates that are invoked from the
  shell rather than linked in (e.g. `gnattest`).

Reaching for `alr with` on a binary-tool crate adds it to the project's
dependency solution but leaves the executable awkwardly scoped to one crate's
environment; `alr install` is the intended path.
