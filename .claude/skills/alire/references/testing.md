# Testing an Alire Crate

Tests are not added to the main crate's `alire.toml`. The Alire convention is
to put tests in a **nested test crate** that depends on the main crate via a
path pin, keeping test-only dependencies (AUnit, mocks, etc.) out of the
published manifest.

Reference: <https://alire.ada.dev/docs/catalog-format-spec#using-pins-for-crate-testing>

## Layout

```text
my_crate/
├── alire.toml            # main crate
├── src/
└── tests/
    ├── alire.toml        # nested test crate
    └── src/
```

## Step 1 — Create the nested test crate

From the main crate's root directory:

```bash
alr -n init --bin tests
cd tests
alr -n with <main_crate_name> --use=..
```

`alr with --use=..` adds the parent crate as a dependency *and* pins it to the
parent directory in a single command. The resulting `tests/alire.toml` will
contain:

```toml
[[depends-on]]
<main_crate_name> = "*"

[[pins]]
<main_crate_name> = { path = '..' }
```

`alr build` from inside `tests/` will now resolve `<main_crate_name>` against
the parent's local sources.

## Step 2 — Add AUnit

AUnit is an ordinary library crate; add it to the test crate with `alr with`:

```bash
alr -n with aunit
```

After this, `tests/alire.toml` will include `aunit = "^<version>"` under
`[[depends-on]]`. AUnit is **only** a dependency of the test crate, never of
the main crate.

## Step 3 — Add GNATtest (test-skeleton generator)

> **Do not** use `alr with gnattest`. GNATtest is a binary tool — a code
> generator that produces an AUnit-based test harness from Ada specs — not a
> library that the test crate links against. It belongs in a shared install
> prefix, not in the test crate's dependency solution.

Install it once, system-wide:

```bash
alr install gnattest
```

This places `gnattest` at `$HOME/.alire/bin/gnattest`. See
[alire-install.md](alire-install.md) for prefix details.

### Invoking gnattest

`$HOME/.alire/bin` is **not** added to `PATH` automatically — not for the
shell, and not even when running under `alr exec`. Plain
`alr exec -- gnattest ...` fails with `Executable not found in PATH`.

Every gnattest invocation must therefore either (a) extend `PATH` for the
call, or (b) use the absolute path:

```bash
# (a) Prepend the install bin dir for the invocation
PATH="$HOME/.alire/bin:$PATH" alr exec -- gnattest -P <project.gpr> ...

# (b) Use the absolute path
alr exec -- "$HOME/.alire/bin/gnattest" -P <project.gpr> ...
```

For interactive sessions, exporting `PATH="$HOME/.alire/bin:$PATH"` once in
the shell (or in a shell rc file) avoids the per-call prefix.

For everything beyond installation — generating skeletons, running the
harness, working with AUnit assertions — see the gnattest skill.
