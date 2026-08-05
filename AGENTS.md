# Flyology agent guide

This file records durable project rules for coding agents. Keep it concise and
update it when the implementation, supported matrix, or verification workflow
changes. `README.md` remains the user-facing architecture reference; executable
scripts remain authoritative for commands, proof totals, and test coverage.

## Project identity and language

- The project is **Flyology**. Do not reintroduce the former project name or
  legacy aliases.
- User-facing task vocabulary is **lightweight task** and **native task**.
  Lightweight tasks run cooperatively on **event loops** in **execution
  groups**. The internal resumable object is a **fiber**.
- Keep “event” terminology for machinery such as event loops, pollers, event
  threads, readiness, and completion. Do not derive a task designation from
  “event,” and do not call tasks processes.
- Write modest, factual prose. Avoid slogans, superlatives, and claims that are
  not tied to a reproducible test, proof run, or benchmark.
- Flyology is experimental. Do not imply production qualification, universal
  portability, hard real-time behavior, or preemptive lightweight scheduling.

## Before changing anything

- Run `git status --short --branch`. Preserve unrelated user changes and do not
  rewrite, discard, or reformat them.
- Read the relevant `README.md` section and the implementation. README prose is
  not evidence when it disagrees with code or a runner.
- Use `rg`/`rg --files` for source discovery.
- Use `apply_patch` for hand edits. Generated formatting and mechanical file
  moves/copies may use their purpose-built commands.
- Keep changes focused. Do not fold an unrelated optimization or experiment
  into a correctness, documentation, or release change.
- When the user requests parallel agents, give each independent change its own
  branch and worktree. Merge only clean, green commits with `git merge
  --ff-only`; do not let agents edit one shared checkout concurrently.
- Run `gh` outside the sandbox. Repository: `flyology-ada/flyology`.

## Execution-model invariants

- An undesignated Ada task is native by default. This is the compatibility and
  inertness contract.
- Explicit designations are `Flyology.Lightweight_Task`,
  `Flyology.Native_Task`, and `Flyology.Project_Default`, supplied through
  GNAT `Task_Info`. The obsolete-feature warning is deliberate; projects use
  `-gnatwJ` while retaining other warnings.
- A task’s lightweight/native designation is captured at creation and cannot
  change while the task is alive. A lightweight task may migrate between event
  loops; a native task remains on its pthread.
- The environment task is always native. Native-only programs must not start a
  poller, event-loop thread, scheduler context, or fiber stack. Event machinery
  starts lazily with the first lightweight task.
- Both lanes remain ordinary Ada tasks and share GNARL rendezvous, protected
  objects, exceptions, activation, masters, abort, and task identity. Do not
  create a parallel async language or reimplement those semantics above GNARL.
- A lightweight task’s `CPU` aspect selects a shared Flyology execution group.
  A native task’s `CPU` aspect retains stock GNARL affinity meaning.
- Shared group ids are `0 .. 127`; dedicated ids are `128 .. 255`. Automatic
  pool size is `1 .. 128` and currently uses deterministic round robin.
- Migration is an explicit safe point. The task resumes on the destination
  group’s stable pthread without changing its Ada identity, stack, locals, or
  exception state. Never allow two loops to restore one fiber concurrently.
- Migrating out of a dedicated group consumes its reservation. Call
  `Create_Dedicated` again before re-entering; the vacated lane may have been
  reused.
- Lightweight tasks in one group share pthread-local state. Use a scoped
  `Thread_Pin` to forbid migration while holding thread-affine state, and a
  dedicated group when exclusive pthread ownership is also required.
- Scheduling inside one group is cooperative. A CPU-bound lightweight task must
  suspend, execute `delay 0.0`, or call a fairness checkpoint. Separate groups
  may execute in parallel. Do not describe this as forced preemption.
- Routed native offload must prepare detached input on the request owner, pass
  only that value through a bounded `Native_Executors` pool, and render on the
  original owner. Native workers must not receive a live exchange or connection.
- Ready queues are per-priority FIFO buckets, deadlines are per-group indexed
  min-heaps, and task/descriptor wake lookups are direct. Avoid reintroducing
  linear all-fiber scans or sorted ready-list insertion on hot paths.
- Topology changes—group allocation, dedicated reservations, migration, and
  destruction—may briefly use the global topology/registry lock. Ordinary
  scheduling and I/O remain per-group.

## I/O invariants

- Public I/O keeps normal synchronous Ada call semantics and works from either
  lane. A lightweight call suspends only its task; a native call may block only
  its pthread. Preserve `out` values, exceptions, retry deadlines, and ownership
  semantics across both paths.
- TLS provider choice is per connection through the provider-neutral SPI.
  OpenSSL is an optional dynamically loaded provider. Provider steps must never
  block: return `Want_Read` or `Want_Write` and let Flyology wait for readiness.
  A provider session borrows the descriptor while `TLS.Connection` retains sole
  closing ownership.
- Socket readiness uses `kqueue` on Darwin and `epoll` on Linux. Cross-thread
  wakes use `EVFILT_USER` or `eventfd` respectively.
- Timers use the group poller’s next timeout and a monotonic deadline heap.
  There is no timer thread or per-task OS timer.
- Regular-file data I/O must be completion-driven, not placed on worker
  threads: POSIX AIO plus `EVFILT_AIO` on Darwin; per-group `io_uring` on Linux
  with Linux native AIO plus `eventfd` as the fallback.
- Native file callers use direct positional syscalls. `Open` and `Close` are
  direct metadata syscalls in both lanes and may occupy a loop on slow remote
  filesystems.
- Linux syscall numbers, native `epoll_event` layout, thread placement, virtual
  memory, test hooks, and the GNAT 13 release-store intrinsic belong in the
  narrow C bridge. Scheduler, queue, timeout, backpressure, file-engine, and
  retry policy belong in Ada.
- Never hide a blocking `pread`, `pwrite`, DNS resolver, or arbitrary foreign
  call on an event-loop pthread. Use the implemented kernel completion path or
  an explicit native-task boundary.
- Preserve descriptor-generation and ownership rules. `Take` transfers sole
  closing ownership; high-level connections serialize operations and make
  cancellation/close generation-safe. Raw socket APIs do not infer ownership.
- A submitted file buffer remains kernel-owned until completion. Abort cannot
  release or reuse it early.
- A `Flyology.Buffers.Unique_Buffer` has exactly one owner. Buffer channels
  transfer the slot token without copying payload bytes; timeout, close, or
  abort before acceptance must restore sender ownership. Pool storage outlives
  every buffer and channel tied to it, and mutation remains exclusive rather
  than reference-counted or atomically shared.

## Runtime and ABI boundaries

- Integration is below GNARL at `System.Task_Primitives.Operations`. Keep the
  patch surface minimal and versioned.
- Event polling, scheduling, and context switching are separate mechanisms.
  Describe the actual `kqueue`/`epoll` poller, Ada scheduler, guarded stacks,
  and small ABI-specific register swap.
- Context assembly exists for AArch64 and x86-64. Preserve all ABI-required
  callee-saved integer, floating-point, stack, frame, and control state, stack
  alignment, and entry conventions. Keep assembly comments explanatory.
- Fiber stacks use guarded `mmap` arenas. Event-loop pthreads, not individual
  fibers, own alternate signal stacks. Overflow must continue to become Ada
  `Storage_Error` through the supported GNARL signal path.
- Do not edit generated copies under `build/rts`. Change `runtime/ada`, the
  platform implementation, the native ABI bridge, configuration templates, and
  the exact versioned patch family as appropriate.
- Runtime patch families fail closed. Never guess a nearby GNAT version or
  weaken a patch hunk to make an unverified compiler pass. The supported matrix
  in `runtime/patches/README.md` and validation in `prepare-rts.sh` are
  authoritative.
- If adding a `System.Flyology.*` runtime unit, compute its krunched filename
  with `gnatkr`; do not guess.
- Event initialization/finalization is one-shot. Finalization occurs only after
  GNARL task masters and controlled library objects are complete. Never tear
  down a loop while a fiber or kernel-owned buffer can still use it.
- After `fork` once Ada tasking was initialized, the child may only perform
  async-signal-safe work followed by `exec` or `_exit`. Do not make the runtime
  usable in the fork child by resetting isolated locks piecemeal.

## Repository map

- `src/`: public Flyology packages and platform-neutral API policy.
- `src/platform/{darwin,linux}/`: public-package platform bodies.
- `runtime/ada/`: scheduler, contexts, poller interfaces, and runtime policy.
- `runtime/platform/{darwin,linux}/`: poller and Ada file-engine bodies.
- `runtime/native/`: context-switch assembly and narrow C/OS ABI bridges.
- `runtime/config/`: generated project-default and loop-pool policy templates.
- `runtime/compat/`: GNAT-version ABI adapters.
- `runtime/patches/`: exact GNAT source-context patches; separately licensed.
- `tests/`: behavioral, parity, lifecycle, stress, fault, sanitizer, and
  observability programs.
- `showcases/`: side-by-side demonstrations and reproducible measurements.
- `proof/`: SPARK-only development crate and runtime policy proof model.
- `scripts/`: all supported build, runtime preparation, test, docs, and proof
  entry points.
- `docker/`: native-architecture Linux validation.
- `assets/brand/`: editable logo sources and rendered previews. The README uses
  separate light- and dark-theme horizontal lockups.

## Toolchain and generated runtime

- Alire 2.1 or newer is required. Scripts resolve Alire through `$ALR`, then
  `alr` on `PATH`, then `~/alr`; use `scripts/find-alr.sh` rather than hardcoding
  a personal path.
- The crate permits GNAT `>=13 & <17`, but runtime preparation accepts only
  exact verified host/release pairs. Do not broaden support from the dependency
  constraint alone.
- `./scripts/prepare-rts.sh` defaults to `FLYOLOGY_DEFAULT=native` and produces
  `build/rts`. Applications must compile with `--RTS=<prepared-runtime>`; the
  public library intentionally does not link against stock GNARL by itself.
- Important preparation controls:
  - `FLYOLOGY_RTS_DIR`: generated RTS destination.
  - `FLYOLOGY_DEFAULT`: `native` or `lightweight`.
  - `FLYOLOGY_LOOP_POOL_SIZE`: `1 .. 128`.
  - `FLYOLOGY_PLACEMENT`: currently `round_robin`.
  - `FLYOLOGY_LOOP_PLACEMENT`: `none`, Linux `strict`, or Darwin `advisory`.
  - `FLYOLOGY_LOOP_PLACEMENT_MAP`: unique `GROUP:VALUE` pairs.
  - `FLYOLOGY_SANITIZER`: `none` or `address`.
  - `FLYOLOGY_TEST_FAULTS` and `FLYOLOGY_TEST_DENY_IO_URING`: test-only `0/1`
    switches; never enable them in a production runtime.
- These settings are compiled into the prepared RTS, not read dynamically by
  the application.
- Flyology serializes its own Alire RTS preparation within one dependency
  checkout. Alire may still mutate `alire/build_hash_inputs` before dependency
  actions, so concurrent full `alr build` processes must not share one local
  path pin. Use a separate Flyology checkout per build or externally serialize
  the builds.
- Treat the Alire RTS input stamp as a transaction commit marker: invalidate it
  before mutating a stale runtime, atomically publish generated configuration,
  and publish the replacement stamp last.
- Do not commit generated `alire`, `config`, `obj`, `lib`, `build`, `docs/api`,
  test binaries, showcase binaries, or copied GNAT runtime sources.

## Verification

Use the smallest relevant checks while iterating, then run the complete checks
required by the changed boundary.

- `./scripts/test.sh`: authoritative behavioral suite, both project defaults,
  runtime preparation validation, and external-consumer test.
- `./scripts/stress.sh`: bounded deterministic concurrency and fault campaign.
- `FLYOLOGY_LONG_SOAK=1 ./scripts/stress-soak.sh`: opt-in long campaign.
- `./scripts/prove.sh`: authoritative SPARK proof run. All reported checks must
  prove. Never hardcode the total in prose; it changes with contracts.
- `./scripts/docs.sh`: GNATdoc HTML generation. It must produce
  `docs/api/index.html` with zero undocumented-entity warnings or errors.
- `./scripts/coverage.sh`: GNATcoverage statement and decision baseline for
  Flyology-owned Ada library units. It requires the `gnatcov_bin` tool crate;
  generated traces and reports remain outside version control.
- `./scripts/websocket-conformance.sh core lightweight`: pinned Autobahn
  server-side framing profile. Run `core native` for lane parity, `core-wss
  lightweight` and `core-wss native` for the same profile through the
  OpenSSL-backed TLS transport,
  and `limits lightweight` plus `limits native` for message-boundary lane
  parity. Run
  `compression lightweight` and `compression native` for the RFC 7692
  compressed-message and negotiation profiles, and repeat them as
  `compression-wss lightweight` and `compression-wss native` for TLS lane
  parity. The runner verifies and records an Alire release/-O3 build. Run
  `performance lightweight` and `performance native`, then repeat them as
  `performance-wss lightweight` and `performance-wss native`, for per-lane and
  per-transport section 9 RTT/echo timing probes. Generated HTML and per-case
  JSON remain under ignored
  `build/autobahn` output. Run `node
  scripts/publish-websocket-conformance.mjs` to restyle every completed profile
  into the checked-in website report bundle.
- `node scripts/publish-websocket-conformance.mjs`: transform all eight local
  Autobahn profiles into compact Flyology-styled pages and normalized JSON
  under `website/reports/websocket`. Regenerate after replacing report data.
- `./scripts/showcases.sh`: build and run the maintained showcase set. Re-run a
  benchmark before changing a performance table or claim.
- `showcases/http-comparison/scripts/run-linux-docker-hybrid.sh`: calibrated
  routed inline/native-pool/fully-native CPU and mixed-load comparison. Preserve
  its raw oha, resource, executor, calibration, and metadata outputs with claims.
- `./scripts/test-linux-docker.sh`: Linux test on the host’s native architecture.
  It removes the successfully built test image on success or failure. Set
  `FLYOLOGY_KEEP_LINUX_IMAGE=1` only when retaining it for inspection.
  `FLYOLOGY_LINUX_ARCH`, `FLYOLOGY_GNAT_VERSION`,
  `FLYOLOGY_GPRBUILD_VERSION`, and `FLYOLOGY_LINUX_IMAGE` select the target and
  image configuration.
- `./scripts/test-alire-runtime-matrix.sh`: exact supported GNAT patch-family
  matrix. Run it when changing GNARL patches, compatibility units, runtime
  preparation, or advertised compiler support.
- Prefer Linux/AArch64 Docker tests on Apple Silicon because they are native and
  faster. Run Linux/amd64 only for x86-64-specific code, ABI assembly, a stated
  release-matrix check, or an explicit user request.
- Runtime, scheduler, poller, file-engine, GNARL patch, stack, assembly, or
  lifecycle changes require `./scripts/test.sh`. Add stress, sanitizer, Docker,
  and architecture-specific checks in proportion to the affected risk.
- Public contracts or policy-kernel changes also require `./scripts/prove.sh`.
  Public spec documentation changes require `./scripts/docs.sh`.
- Documentation/artwork-only changes need syntax/link/XML checks as applicable;
  do not spend hours rebuilding an unrelated RTS.
- Changes to `alire.toml` require `alr show`; keep Alire tags within its
  15-character tag limit.
- CI in `.github/workflows/ci.yml` is the hosted reference. Do not add
  `continue-on-error` to conceal a backend failure.

## Ada, documentation, and test style

- Preserve ordinary Ada call semantics and exception contracts. Prefer typed
  wrappers over unstructured address arithmetic; isolate unavoidable ABI
  conversions.
- Public `src/*.ads` entities use GNATdoc leading comments with no blank line
  between comment and declaration. Keep exact `@param`, `@return`,
  `@exception`, `@field`, `@enum`, `@formal`, and `@exclude` names. The docs
  script fixes `--style=leading`.
- Document lane-specific blocking, timeout units and deadline scope,
  cancellation latency, ownership/lifecycle, task safety, cooperative fairness,
  and group migration where they affect callers. Do not restate signatures.
- Runtime specs are maintainer-facing and outside public GNATdoc scope, but
  still need comments for locking, ownership, state transitions, and ABI facts.
- Tests should assert behavior and resource/lifecycle invariants, not merely
  successful exit. For lane parity, compare only outcomes and ordering required
  by Ada—not scheduler traces or wall-clock coincidences.
- Keep test fault injection compiled out of production and isolate expected
  aborts/process exits in subprocesses with timeouts.

## Licensing and commits

- Original code, tests, scripts, proof, and artwork are dual MIT/Apache-2.0.
- Files under `runtime/patches/` contain GNAT-derived context and are
  GPL-3.0-or-later WITH GCC-exception-3.1. Preserve the notice atop every patch
  and the carve-out in `runtime/patches/LICENSE`.
- `prepare-rts.sh` may copy the user’s installed GNAT sources into ignored build
  output. Complete GNAT sources must never enter the repository.
- Use focused Problem/Solution commit messages:

  ```text
  Problem: <present-tense problem statement>

  <Impact and repository context.>

  Solution: <one-line solution statement>

  <What changed and why.>
  ```

- Before committing, run `git diff --check`, inspect every staged path, and
  report the exact checks run. Do not claim hosted CI is green until its run is
  complete.
