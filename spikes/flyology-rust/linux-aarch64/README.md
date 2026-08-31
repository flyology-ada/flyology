# Linux/AArch64 Rust bridge matrix

This portability spike runs every integrated Ada/Rust bridge spike in the
repository's native-architecture Linux Docker environment. It reuses the
standard Flyology Linux image so the Ada side stays on the supported patched
GNAT 16.2 and GPRbuild 26.0.1 toolchain, then adds pinned Rust 1.97.1.

Run from any directory:

```sh
./spikes/flyology-rust/linux-aarch64/run.sh
```

The default target is Linux/AArch64. The runner builds two local images, runs
the suite, and removes both images even after failure. Set
`FLYOLOGY_KEEP_RUST_LINUX_IMAGES=1` to retain them. An explicit
`FLYOLOGY_RUST_LINUX_ARCH=amd64` selects Linux/x86-64, but that target is not
part of the evidence recorded below.

The container prints exact kernel, distribution, Rust, Alire, GNAT, and
GPRbuild versions before running:

1. ABI layout, ownership, thread-local state, and panic translation with
   static and dynamic Rust libraries in debug and release profiles;
2. the Ada-hosted Tokio bridge stress pass on both task lanes;
3. Rust-hosted Ada initialization, foreign-thread registration, native and
   lightweight child creation, and finalization;
4. direct future polling, wake-before-arm, delayed wake, cancellation, and
   isolated native/lightweight panic probes;
5. the explicit static/dynamic unwind matrix on both Ada task lanes.

Cargo is offline during the test run. The image build is the only stage that
fetches the Tokio version pinned by the existing `Cargo.lock`.

## Evidence from 2026-08-31

The native Linux/AArch64 run used Docker 29.4.0 on an AArch64 engine, Ubuntu
24.04.4, Flyology's `gnat_flyology_native=16.2.0-patchset.1.1.0`, the Alire
`gprbuild=26.0.1` package, Rust/Cargo 1.97.1, and Tokio 1.53.1. The selected
GPRbuild binary identifies itself as `GPRBUILD 26.0.0 (2026-04-15)`.

The standalone ABI matrix passed static and dynamic linking in debug and
release. Rust `catch_unwind` translated the intentional panic in all four
cases. This differs from the Darwin/AArch64 GNAT-GCC static-link result:
Linux's GNAT link retained the DWARF unwind information needed by Rust, while
the tested Darwin GNAT-GCC link omitted the required compact-unwind metadata.
The Linux ABI case uses the selected GNAT's `gnatmake` and `gnatlink`; it does
not need the patched Flyology runtime or a Flyology archive.

The complete matrix then failed closed at the supported GPRbuild probe. The
probe reproduces the two commands used by `scripts/test.sh` for one established
`tests/runtime_smoke.gpr` main, `default_policy_smoke.adb`: first recursive
compile with `-c`, then bind/link with `-b -l`, both against the prepared
runtime. GPRbuild returned status zero after binding but created no executable.
The preceding library build left objects and `.lexch` files but created no
`libFlyology.a`.

The installed helper directory contained `gprbind`, `gprdoc`, `gprdriver`, and
`gprlib`, but no `gprlink`. Setting `GNAT_GPR_ENGINE=2` did not alter the result,
and this binary rejected the documented `--gpr=2` option. These observations
point to a mismatched or incomplete GPRbuild package rather than an Ada/Rust
bridge failure.

Consequently, this run provides no Linux result for the Ada-hosted Tokio
stress, Rust-hosted Ada tasking, direct futures on a Flyology group, or the
native/lightweight unwind matrix. Those cases require the missing Flyology
archives or a GPR-produced executable. Repairing the selected GPRbuild package
so its link helper produces archives and executables is a prerequisite for
rerunning them. The runner keeps those cases behind the exact probe and does
not weaken their criteria. A passing complete run must end with
`PASS Linux Rust bridge spike matrix`.
