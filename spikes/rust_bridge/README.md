# Flyology Rust bridge spikes

These programs test possible Ada/Rust interoperability boundaries before a
public bridge API is designed. Each directory is an executable experiment with
its own hypotheses, failure criteria, and runner.

The spikes are not supported Flyology APIs. They intentionally keep Rust values
behind a C ABI and make ownership and runtime lifecycle visible in the test.

## First wave

- `abi`: Ada-owned executable linked to the same Rust library as a static
  archive and a dynamic library.
- `ada_hosts_rust`: Ada tasks submit asynchronous work to a Rust-owned engine.
- `rust_hosts_ada`: a Rust-owned executable initializes and calls tasking Ada.
- `direct_futures`: a Flyology operation directly polls a Rust future.

