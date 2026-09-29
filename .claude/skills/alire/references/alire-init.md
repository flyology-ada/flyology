# Creating a Project

**No toolchain setup required first.** `alr -n init` (and the subsequent `alr -n build`) will fetch a default GNAT + gprbuild on first use if none is selected. Do not pre-run `alr toolchain --select` — see [alire-toolchain.md](alire-toolchain.md) for the rare cases that warrant it.

Collect from the user before proceeding:
- **Project name** — lowercase, alphanumeric, underscores allowed (e.g. `my_project`)
- **Project description** — a short one-line description
- **Project type** — `Binary` (default) or `Library`

Initialize in non-interactive mode:
```bash
alr -n init --bin <project_name>   # binary
alr -n init --lib <project_name>   # library
```

Update the `description` field in `<project_name>/alire.toml` using the Edit tool, then verify:
```bash
cd <project_name> && alr -n build
```
