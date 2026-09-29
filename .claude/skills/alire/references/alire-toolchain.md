<!-- Modified by flyology-ada/agents: normalized trailing whitespace. -->

# Managing Toolchains


**You almost never need this.** `alr init` and `alr build` auto-install a default GNAT + gprbuild on first use, so
there is no "install the toolchain first" step before creating or building a crate. Jump straight to [alire-init.md
(alire-init.md) for new projects.

Only reach for `alr toolchain` when:
- The user explicitly asks to pin a specific GNAT version.
- You need to inspect what's currently installed (`alr toolchain` with no arguments).

This section should only be used as a last resort and only if you are sure there is no other solution. Always
ask the user before selecting a toolchain version. Selecting a toolchain version is like hard-coding a compiler
and can create problems if some of the crates depend on other compilers.


List available toolchains:
```bash
alr toolchain
```

*Note*: `alr toolchain --select` without an actual selection is an interactive tool, so not useful for the skill. Instead, list available toolchain versions for a specific compiler and then select the correct one:
```bash
alr search --list gnat_native
```

Select a specific GNAT version non-interactively:
```bash
alr -n toolchain --select gnat_native=<version>
```

Select a specific cross-compiler (e.g. for ARM):
```bash
alr -n toolchain --select gnat_arm_elf=<version>
```

## macOS Toolchain Compatibility

On newer macOS versions (Darwin 25+), some GNAT toolchain versions may fail to link with:

```text
ld: library not found for -lSystem
```

This occurs when the toolchain was built for an older macOS SDK. Workarounds:

**Option A: Try an older toolchain version**
```bash
alr search --list gnat_native
alr toolchain --select gnat_native=14.2.1
```

**Option B: Set SDKROOT explicitly**
```bash
export SDKROOT=$(xcrun --show-sdk-path)
alr build
```

Note: Older toolchains (e.g., 14.2.1) may have the duplicate `LC_RPATH` issue - see [alire-build.md](alire-build.md) for the fix.
