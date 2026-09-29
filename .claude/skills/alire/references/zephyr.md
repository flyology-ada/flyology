<!-- Modified by flyology-ada/agents: normalized trailing whitespace. -->

# Building Ada for Zephyr

Works for any Zephyr board with a GNAT toolchain available in Alire —
**Arm Cortex-M** (`gnat_arm_elf`) or **RISC-V** (`gnat_riscv_elf`). Only the
`alire.toml` dependency, the GPR `Target` / `Runtime` / compiler flags, and
the Zephyr `BOARD` value change between targets.

Unlike a bare-metal BSP (e.g. `pico_bsp`), Zephyr owns the top-level build.
The Ada/SPARK code is compiled into a **static library** by `gprbuild`, and
Zephyr's CMake build links that library into the final firmware image.

The running example is the **NUCLEO-H563ZI** (STM32H563ZI, Cortex-M33 with
single-precision FPU). RISC-V differences are called out in the tables and
pitfalls sections.

The west toolchain needs to be available on the command-line, it is best to start
a build process and ideally the LLM CLI in a virtual environment.

## Required toolchain

Declare the cross toolchain as Alire dependencies so a fresh clone just
works — no manual `alr toolchain --select`. Alire downloads and caches
them on the first `alr build` / `alr exec`.

Use `alr init --lib` to create the project structure, this creates the alire.toml and the
GPR file.

Use `alr with` to select the toolchain, for example `gnat_arm_elf` or `gnat_riscv_elf`

No BSP crate is pulled in — Zephyr provides the HAL, device tree, and
driver layer. The cross toolchain is discovered at build time from `PATH`,
which `alr exec` populates from the above dependencies.

## Project layout

```
project/
├── alire.toml                   Ada deps (gnatprove + cross toolchain)
├── my_app.gpr                   GPRbuild file
├── CMakeLists.txt               Zephyr app; invokes gprbuild, links libada
├── prj.conf                     Zephyr Kconfig fragment
├── app.overlay                  Board device-tree overlay
├── west.yml                     West manifest pinning Zephyr version
├── Makefile                     Wraps west with `alr exec`
└── src/
    ├── main.adb / *.adb / *.ads Ada/SPARK sources (main.adb = entry point)
    ├── ada_main.c               C trampoline: main() → adainit() → _ada_main()
    └── *_zephyr.c               C shims calling Zephyr APIs
```

## Steps

### 1. Build Ada as a static library

The GPR declares `Library_Kind = "static"` so the output is a `.a` archive that
CMake can link.

Take the my_app.gpr that is generated and modify Target and Runtime to be like the following,
based on the target and runtime table. Do **not** add a `Compiler` package with runtime switches. The runtime
already encodes the correct ABI and `gprbuild` picks it up automatically. Those flags are only needed in the raw `gcc` call inside the CMakeLists.txt binder step (Step 2).


```ada
   for Target use "arm-eabi";
   for Runtime ("Ada") use "light-cortex-m33f";
```

Target and runtime for common MCUs:

**Arm Cortex-M** (`gnat_arm_elf`, `Target = "arm-eabi"`)

| MCU | `Runtime` |
|---|---|---|
| Cortex-M0+ (RP2040) | `light-cortex-m0p` |
| Cortex-M4F (STM32F4) | `light-cortex-m4f` |
| Cortex-M7F (STM32H7) | `light-cortex-m7df` |
| Cortex-M33F (STM32H5) | `light-cortex-m33f` |

**RISC-V** (`gnat_riscv_elf`, `Target = "riscv64-elf"` — multilib handles 32/64)

| Core profile | Typical `Runtime` |
|---|---|---|
| RV32IMC (no FPU, e.g. ESP32-C3) | `light-riscv32` (or board-specific) |
| RV32IMAC (e.g. HiFive1) | `light-hifive1`  |
| RV32IMFC (single-prec FPU) | *check availability* |
| RV64IMAC | *check availability* |

Runtime availability varies with GNAT version. List what your toolchain
ships with:

```bash
alr exec -- gnatls --RTS=? --target=arm-eabi       # or riscv64-elf
```

If the specific `light-*` RTS is missing, fall back to `zfp-*`  for the closest architecture.

### 2. CMakeLists.txt — invoke gprbuild and link the library

This block is **target-neutral**: the compiler name drives everything. For
RISC-V, change `arm-eabi-gcc` to `riscv64-elf-gcc` (or whatever your
`gnat_riscv_elf` crate ships). The `ADA_TARGET` / `ADA_TOOL_PREFIX`
variables are derived from the compiler name, so the rest of the file
needs no edits.

```cmake
cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(my_app)

# Pick the compiler matching your Alire cross crate:
#   gnat_arm_elf   → arm-eabi-gcc
#   gnat_riscv_elf → riscv64-elf-gcc
find_program(ADA_COMPILER arm-eabi-gcc REQUIRED)
find_program(ADA_GPRBUILD gprbuild     REQUIRED)
# gnatbind is the cross binder; may be prefixed or unprefixed depending on
# how the Alire crate packages it.
find_program(ADA_GNATBIND NAMES arm-eabi-gnatbind gnatbind REQUIRED)

get_filename_component(ADA_BIN_DIR       "${ADA_COMPILER}" DIRECTORY)
get_filename_component(ADA_TOOLCHAIN_DIR "${ADA_BIN_DIR}"  DIRECTORY)

# Derive tool prefix from the compiler name
# (arm-eabi-gcc → arm-eabi-, riscv64-elf-gcc → riscv64-elf-).
get_filename_component(_stem "${ADA_COMPILER}" NAME_WE)
string(REGEX REPLACE "-gcc$" "" ADA_TARGET "${_stem}")
set(ADA_TOOL_PREFIX "${ADA_TARGET}-")

# Parse the RTS name out of the GPR so it stays a single source of truth.
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/my_app.gpr" _gpr)
string(REGEX MATCH "for Runtime \\(\"Ada\"\\) use \"([^\"]+)\"" _ "${_gpr}")
set(ADA_RTS "${CMAKE_MATCH_1}")

# libgnat.a lives inside the RTS — needed for elaboration/runtime support.
# gnatbind also needs the absolute RTS dir (it does not accept a bare name
# the way gprbuild does; --RTS=<name> fails with "missing adainclude" there).
set(ADA_RTS_DIR "${ADA_TOOLCHAIN_DIR}/${ADA_TARGET}/lib/gnat/${ADA_RTS}")
find_file(ADA_LIBGNAT "libgnat.a"
  PATHS "${ADA_RTS_DIR}/adalib"
  NO_DEFAULT_PATH REQUIRED)

set(ADA_OBJ_DIR "${CMAKE_CURRENT_BINARY_DIR}/ada_obj")
set(ADA_LIB     "${ADA_OBJ_DIR}/lib/libada_app.a")
file(MAKE_DIRECTORY "${ADA_OBJ_DIR}")

file(GLOB_RECURSE ADA_SOURCES CONFIGURE_DEPENDS "src/*.ads" "src/*.adb")

if(WIN32)
  set(_psep ";")
else()
  set(_psep ":")
endif()

add_custom_command(
  OUTPUT "${ADA_LIB}"
  COMMAND ${CMAKE_COMMAND} -E env
    "PATH=${ADA_BIN_DIR}${_psep}$ENV{PATH}"
    "GPR_TOOL_PREFIX=${ADA_TOOL_PREFIX}"
    "${ADA_GPRBUILD}"
      -P "${CMAKE_CURRENT_SOURCE_DIR}/my_app.gpr"
      -j0 --target=${ADA_TARGET}
      -XADA_OBJ_DIR="${ADA_OBJ_DIR}"
  DEPENDS ${ADA_SOURCES} "${CMAKE_CURRENT_SOURCE_DIR}/my_app.gpr"
  WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
  COMMENT "Compiling Ada for ${ADA_TARGET} (${ADA_RTS})")
add_custom_target(ada_lib ALL DEPENDS "${ADA_LIB}")

# ── Bind the Ada main ───────────────────────────────────────────────────
# gprbuild with Library_Kind=static does NOT run the binder, so libada_app.a
# has no adainit / adafinal / main bridge. Run gnatbind -n on main.ali to
# emit ada_bind.adb (defines adainit/adafinal), then compile that file.
# The C trampoline in src/ada_main.c calls adainit() then _ada_main().
#
# !!! IMPORTANT: the -mcpu / -mthumb / -mfpu / -mfloat-abi flags below
# must match the Default_Switches in your cross GPR exactly. The example
# uses Cortex-M33F; for any other target copy whatever is in the GPR's
# Compiler package. This is the one part of the recipe that is NOT
# derived from ADA_TARGET / ADA_RTS automatically.
set(ADA_BINDER_OBJ "${ADA_OBJ_DIR}/ada_bind.o")
add_custom_command(
  OUTPUT "${ADA_BINDER_OBJ}"
  COMMAND ${CMAKE_COMMAND} -E env
    "PATH=${ADA_BIN_DIR}${_psep}$ENV{PATH}"
    "${ADA_GNATBIND}" -n --RTS=${ADA_RTS_DIR} -o ada_bind.adb main.ali
  COMMAND ${CMAKE_COMMAND} -E env
    "PATH=${ADA_BIN_DIR}${_psep}$ENV{PATH}"
    "${ADA_COMPILER}" -c --RTS=${ADA_RTS_DIR}
      -mcpu=cortex-m33 -mthumb -mfpu=fpv5-sp-d16 -mfloat-abi=hard  # ← match GPR
      -o ada_bind.o ada_bind.adb
  WORKING_DIRECTORY "${ADA_OBJ_DIR}"
  DEPENDS "${ADA_LIB}"
  COMMENT "Binding Ada main → ada_bind.o (adainit/adafinal)")
add_custom_target(ada_binder ALL DEPENDS "${ADA_BINDER_OBJ}")

# ── Sources ─────────────────────────────────────────────────────────────
# Zephyr compiles exactly the C files listed here. This is an explicit
# allowlist — files in src/ that aren't listed are ignored. If you
# remove a file from this list, delete it from src/ too so the next
# contributor doesn't mistake it for live code.
target_sources(app PRIVATE
  src/ada_main.c       # C trampoline → adainit() → _ada_main()
  src/hal_zephyr.c     # Zephyr API shims callable from Ada
)

# ── Link ────────────────────────────────────────────────────────────────
add_dependencies(app ada_lib ada_binder)
target_link_libraries(app PRIVATE
  "${ADA_BINDER_OBJ}"  # adainit / adafinal
  "${ADA_LIB}"         # _ada_main + compiled Ada packages
  "${ADA_LIBGNAT}")    # runtime support

# Zephyr libc and the Ada RTS both define `abort`; let the linker keep one.
zephyr_ld_options("-Wl,--allow-multiple-definition")

# Ada's light runtime s-memory.adb references __heap_start / __heap_end
# from the linker script; Zephyr provides neither. Define both to 0 for a
# no-heap target (any Ada allocation raises Storage_Error). See "Allocator
# options" below for bump-heap and libc-bridge alternatives.
zephyr_ld_options(
  "-Wl,--defsym=__heap_start=0"
  "-Wl,--defsym=__heap_end=0")
```

### 2b. C trampoline — `src/ada_main.c`

Zephyr's startup calls `int main(void)`. The Ada side provides
`procedure Main` in `src/main.adb`, which `gnatbind -n` exposes as the
C symbol `_ada_main` alongside `adainit` / `adafinal`. This ten-line
file bridges them:

```c
/*
 * ada_main.c — Zephyr C entry point for an Ada/SPARK application.
 * adainit() runs package elaboration; _ada_main() is the Ada main.
 * Most embedded Ada main procedures loop forever, so the spin is
 * defensive — normal flow never returns.
 */
extern void adainit(void);
extern void _ada_main(void);

int main(void)
{
	adainit();
	_ada_main();
	for (;;) { }
}
```

The symbol `_ada_main` is GNAT's convention for a top-level `procedure
Main` (the `_ada_` prefix + unit name). If you rename the Ada main
procedure, the C symbol follows.

### 2c. Bridging Zephyr's inline APIs to Ada

Many Zephyr functions are declared `static inline` in headers rather
than as regular externs — notably most of `<zephyr/net/socket.h>`
(`zsock_poll`, `zsock_recv`, etc.) and parts of the kernel helper set.
They have no linkable symbol, so `pragma Import` on the Zephyr name
fails at link time with `undefined reference`, even though the same
call from C compiles fine.

For each inline API Ada needs to call, add a one-line wrapper in a
C shim file. Convention: prefix with `ada_` to mark the boundary.

```c
/* In src/hal_zephyr.c (or a dedicated shim file) */
#include <zephyr/net/socket.h>

int ada_sock_poll(struct zsock_pollfd *fds, int nfds, int timeout)
{
	return zsock_poll(fds, nfds, timeout);
}
```

```ada
--  In main.adb (or a binding package)
function Zsock_Poll (Fds : access Pollfd; Nfds, Timeout : int) return int
  with Import, Convention => C, External_Name => "ada_sock_poll";
```

Rule of thumb: if `nm libzephyr.a | grep <name>` returns nothing but
the C call compiles, you need a wrapper.

### 2d. Allocator options

The `defsym=__heap_start=0 defsym=__heap_end=0` choice above is the
"no heap" setting. If Ada code needs allocation, remove that and:


**Bridge to libc/Zephyr heap (general):** override `__gnat_malloc` and
`__gnat_free` in a C file to forward to `malloc`/`free`. Then Ada and
C share one heap and deallocation works.
```c
#include <stdlib.h>
void *__gnat_malloc(size_t n) { return malloc(n); }
void  __gnat_free(void *p)    { free(p); }
```
Combine with `-Wl,--allow-multiple-definition` (already set) so your
version wins over the one in `libgnat.a`.



### 3. prj.conf — match the ABI

The Ada side and Zephyr side must agree on the FP ABI, or the link produces
a silently-broken image (crashes on the first float op).

- **Arm hard-float RTS** (`*-m4f`, `*-m7df`, `*-m33f`, …) → set
  `CONFIG_FPU=y`.
- **RISC-V with F/D extensions** (`ilp32f`, `ilp32d`, `lp64f`, `lp64d`) →
  set `CONFIG_FPU=y` and make sure the Zephyr board/SoC Kconfig enables the
  matching extension. Soft-float (`ilp32`, `lp64`) → leave `CONFIG_FPU=n`.

STM32H563ZI example:

```
CONFIG_FPU=y
```

### 4. west.yml — pin Zephyr

```yaml
manifest:
  projects:
    - name: zephyr
      url: https://github.com/zephyrproject-rtos/zephyr
      revision: v4.4.0
      import: true
  self:
    path: My-App
```

Run once: `west init -l .` then `west update`.

### 5. Makefile — wrap west with `alr exec`

`alr exec -- <cmd>` runs `<cmd>` with `PATH`, `GPR_TOOL_PREFIX`, and other
Alire environment set — so CMake's `find_program(<compiler>)` and
`find_program(gprbuild)` succeed without hardcoded paths. Works identically
on Linux and Windows.

```makefile
BOARD     ?= nucleo_h563zi           # or hifive1_revb, esp32c3_devkitm, ...
BUILD_DIR ?= build

build:
	alr exec -- west build -b $(BOARD) -d $(BUILD_DIR)

pristine:
	alr exec -- west build -b $(BOARD) -d $(BUILD_DIR) --pristine

flash:
	alr exec -- west flash -d $(BUILD_DIR)
```

### 6. Build & flash

First clone only — Alire resolves and installs the cross toolchain
automatically from the `alire.toml` dependencies:

```bash
alr update         # fetches gnat_{arm,riscv}_elf + gprbuild the first time
west init -l .     # once per checkout
west update        # fetches the pinned Zephyr tree
make               # incremental build
```

Day-to-day:

```bash
make           # incremental
make pristine  # clean rebuild
make flash     # flash via the board's on-board debugger
```

## Common pitfalls

- **Missing `GPR_TOOL_PREFIX`.** Without it, `gprbuild --target=<triple>`
  still tries to call host `gcc`/`ar`. CMake sets it from the derived
  `ADA_TOOL_PREFIX` (e.g. `arm-eabi-`, `riscv64-elf-`).
- **Multiple definition of `abort`.** Both the Ada RTS and Zephyr's libc
  provide it. Resolve with `-Wl,--allow-multiple-definition`.
- **FPU / ABI mismatch.** Forgetting `CONFIG_FPU=y` when the Ada RTS is a
  hard-float variant produces a link that "works" but crashes on the first
  float op. Keep the RTS name and `CONFIG_FPU` setting in sync. On RISC-V
  the `-mabi` suffix (`ilp32` vs `ilp32f` vs `ilp32d`) must match on both
  the Ada and C sides — a mismatch usually surfaces as linker errors about
  conflicting ABIs rather than a silent miscompile.
- **RISC-V `-march` extensions must match the SoC.** `rv32imac` on a core
  that lacks the `A` (atomic) extension link-fails at best, traps at worst.
  Cross-check with the Zephyr board's `SOC_SERIES_*` Kconfig before
  picking flags.
- **Do not hardcode Alire toolchain paths** (`~/.local/share/alire/...`) in
  `CMakeLists.txt`. They include version hashes that change. Use
  `find_program` and let `alr exec` put the right binaries on `PATH`.
- **`Library_Kind` must be `static`.** A relocatable or dynamic library
  will not link cleanly into a Zephyr image.
- **No `main()` without a binder step.** `gprbuild` on a static-library
  project does not run `gnatbind`, so `libada_app.a` has no `adainit`,
  `adafinal`, or C `main()`. The symptom is either a missing `main`
  symbol at link time, or — if some stale C `main()` is still in the
  tree — the Ada side silently never runs. Fix is Step 2b's trampoline
  plus the explicit `gnatbind -n` invocation.
- **`--RTS=<name>` works for gprbuild, not for gnatbind.** `gprbuild`
  resolves `--RTS=light-cortex-m33f` against its RTS search paths.
  `gnatbind` (and `gcc` when compiling the bind unit directly) treats
  the argument as a relative path and fails with *"RTS path …: missing
  adainclude and adalib"*. Pass the absolute RTS directory instead:
  `--RTS=${ADA_TOOLCHAIN_DIR}/${ADA_TARGET}/lib/gnat/${ADA_RTS}`.
- **Zephyr `static inline` APIs aren't linkable from Ada.** Macros are
  the well-known obstacle, but plain `static inline` functions in
  Zephyr headers have the same effect: no symbol for `pragma Import`
  to bind to. `zsock_poll` and most of `<zephyr/net/socket.h>` are
  the common offenders. Wrap each in a one-line C extern (Step 2c).
  Diagnostic: `nm build/zephyr/libzephyr.a | grep <name>` returns
  nothing but C callers compile — that's an inline.
- **`__heap_start` / `__heap_end` aren't provided by Zephyr.** The
  light runtime's `s-memory.adb` references these linker symbols, and
  the binder pulls `s-memory.o` in whether or not any Ada code
  actually allocates. Without one of the three allocator options in
  Step 2d, the link fails with undefined references to both symbols.
- **Stale C files in src/ are a trap.** The GPR doesn't compile them
  (Ada-only projects ignore `.c` entirely), but CMake's
  `target_sources(app PRIVATE …)` is an explicit list — if a legacy
  file from a previous port is still listed there, it still builds,
  and its symbols bleed into the link. The failure mode points
  nowhere near the real cause: during the STM32H5 port of Open-Sesame
  a leftover Pico W `main.c` in `target_sources` produced
  *"undefined reference to `NET_REQUEST_WIFI_CONNECT`"* on a board
  with no WiFi subsystem. Fix is to **delete the file**, not to add
  it to the GPR's `Excluded_Source_Files` (that attribute only
  affects Ada sources — it does nothing for `.c`).
