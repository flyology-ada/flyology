---
name: alire
description: This skill should be used when the user wants to "use Alire", "install Alire","create an Alire project", "add a crate", "set up tests for an Alire crate", "add AUnit / GNATtest to an Alire project", or otherwise refine the crate structure of an Ada project
license: Apache-2.0
metadata:
  version: "0.1.0"
  source_repository: "https://github.com/AdaCore/skills"
  source_revision: "ab0360b0adcb0c0831bc2836aaa4d4bcfdc9cf74"
  modified_by: "flyology-ada/agents"
---

# Alire Package Management Skill

## Prerequisites

Check whether `alr` is available:
```bash
alr --version 2>/dev/null || ~/.local/bin/alr --version 2>/dev/null
```

**If Alire is NOT installed**, ask the user if they would like you to install Alire for them.

If the user says "no", direct the user to visit "https://alire.ada.dev/" and stop.

If the user says "yes", follow the instructions in [installing-alire](references/installation.md) to install Alire.

Note: `alr` has comprehensive built-in help. At any point, `alr --help` lists all available subcommands and `alr
`<subcommand> --help` gives full usage details. Consult these whenever the reference files don't fully address the situation.

---

## Quick Reference Chart

| Alire Command | Description | Reference |
|---|---|---|
| — | Install Alire | [installation.md](references/installation.md) |
| `alr search` | Search for crates in the index | [alire-search.md](references/alire-search.md) |
| `alr toolchain` | Inspect or pin compiler toolchains (optional — `alr init`/`alr build` auto-install  default toolchain on first use) | [alire-toolchain.md](references/alire-toolchain.md) |
| `alr get` | Fetch a crate from the index | [alire-get.md](references/alire-get.md) |
| `alr with` | Add a dependency | [alire-with.md](references/alire-with.md) |
| `alr pin` | Pin a dependency to a local path or Git repo | [alire-pin.md](references/alire-pin.md) |
| `alr install` | Install a binary-tool crate to a shared prefix | [alire-install.md](references/alire-install.md) |
| `alr build`  | Build the project | [alire-build.md](references/alire-build.md) |
| `alr run` | Run the project | [alire-run.md](references/alire-run.md) |
| `alr exec`  | Execute a command in the project environment | [alire-exec.md](references/alire-exec.md) |
| `alr printenv` | Print environment variables | [alire-printenv.md](references/alire-printenv.md) |
| — | Set up tests for a crate (AUnit, GNATtest) | [testing.md](references/testing.md) |
| — | Cross-compile for Raspberry Pi Pico | [raspberry-pi-pico.md](references/raspberry-pi-pico.md) |
| — | Cross-compile for Zephyr (Arm / RISC-V) | [zephyr.md](references/zephyr.md) |

   Commands Not in the Reference Chart

  If the user requests an alr workflow not covered above:

  1. Run `alr --help` to confirm the subcommand exists
  2. Run `alr <subcommand> --help` to read its full usage
  3. If the user asked a question, use the help output to answer it. If the user asked you to do something, execute the
  workflow derived from the help output.
