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
  GNAT `Task_Info`. Current GNAT emits an obsolete-feature warning for this
  mechanism. The warning is an artifact of the current design and GNAT's
  handling of it, not intended Flyology behavior. Projects use `-gnatwJ` while
  retaining other warnings. Alternative designation mechanisms, including Ada
  aspects, remain open if toolchain support becomes available.
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
  pool size is `1 .. 128` and currently uses deterministic round robin. The
  RTS reads `FLYOLOGY_LOOP_POOL_SIZE` once at process startup, falls back to
  the prepared value when absent, and establishes the initial size before task
  activation. The ceiling may grow under the topology lock or cooperatively
  drain automatically managed tasks to a smaller size. Drainage retains
  already-created event-loop threads. A reduction with no automatic task or
  pre-cutover placement claim outside its target starts no group, preserving
  the dormant native-only path.
- Ada reserves `CPU => 0` as `Not_A_Specific_CPU`, so only `1 .. 127` name a
  group. `CPU => 0` and an absent aspect both take automatic placement; group
  0 is reachable only through automatic placement or migration. Do not
  document `0` as a group selector.
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
- Per-group loop utilization is measured only on the idle path: a loop times
  the poller wait it takes when nothing is ready, and a snapshot adds a wait
  still in progress instead of charging it as busy time. Do not add a clock
  read to dispatch, context switch, or any other path a busy loop repeats.
- Topology changes—group allocation, dedicated reservations, migration, and
  destruction—may briefly use the global topology/registry lock. Ordinary
  scheduling and I/O remain per-group.

## I/O invariants

- Public I/O keeps normal synchronous Ada call semantics and works from either
  lane. A lightweight call suspends only its task; a native call may block only
  its pthread. Preserve `out` values, exceptions, retry deadlines, and ownership
  semantics across both paths.
- Scoped operation overloads are additive. Keep the synchronous overload and
  implement both forms through the same provider state machine when that
  provider has been converted. The scoped form must not create a helper task,
  task stack, callback thread, or steady-state heap allocation.
- Use a function that returns a limited operation when the operation is the one
  natural result and build-in-place initialization is clear. Use an `out`
  operation parameter when a procedure produces fresh caller-owned operation
  state or several outputs. Use `in out` only when initiation reads and mutates
  established request state, such as an explicit rearm or restart. Keep every
  other formal mode semantic: immutable and borrowed inputs are `in`, writable
  buffers or transferred ownership are `in out`, and values produced without
  reading their prior state are `out`.
- A scoped operation is limited and belongs to one bounded completion set. The
  set must outlive every associated operation. A pending operation retains all
  borrowed actual parameters until terminal completion. Scope exit, abort, and
  cancellation must cancel and drain any provider that can retain kernel or
  runtime references before operation or buffer storage is reclaimed.
- A first-class wait gate is a regular scoped operation and consumes one set
  slot. It observes a fixed nonempty snapshot of generation-stamped operations
  or earlier gates in the same set. References are values without Ada access
  components and must not outlive their set. Retain each observed terminal
  member until all dependent gates terminalize; gate cancellation detaches only
  the observer. Terminal gates count every outcome, while success gates fail as
  soon as their threshold is impossible. Gate propagation is a bounded stable
  scheduler cut and must not allocate, poll, or wake the owner per edge.
- Resolve every started operation once with its provider-specific `Finish` in
  normal code. `Finish` commits outputs, reports the retained provider error,
  and releases capacity. `Consume` is explicit result discard. Controlled
  finalization is only the cancel/drain/discard safety net. An `out` result from
  a `Finish` that raises is undefined under normal Ada copy-out rules.
- Scoped provider drivers run only on the owner task stack. `Start` reserves an
  operation's set slot; each bounded `Drive` step must arm readiness or a
  deadline, retain an external-completion source, continue after one child, or
  publish one terminal outcome. An operation-producing function is an eager
  user-visible root. For provider composition, the parent owns typed child
  operation objects as discriminant-constrained record components, starts one
  through its public `in out` overload, and calls `Continue_After`. The set
  drives the child but hides it from user batches and gates, then resumes the
  parent with `Dependency_Changed`. The parent must call the child's typed
  `Finish` and `Release` before starting another child or completing itself.
  Cancellation must propagate through the active child and drain it before the
  parent terminalizes. A driver must not nest a completion-set wait, call a
  blocking synchronous wrapper, invoke user code on the scheduler stack, or
  release a kernel-owned buffer before terminal completion.
- Current scoped providers cover descriptor readiness, timers, raw stream and
  datagram socket arrays, unique-buffer stream operations, and lightweight
  positional file arrays. A scoped datagram receive retains its addressing,
  truncation, and ECN metadata until typed `Finish`; an empty array still
  receives or sends one zero-length datagram. The file provider uses one
  caller-owned runtime node per
  operation and one lazily created completion wake source per set. Transient
  kernel submission pressure queues those nodes without failing the operation;
  queued cancellation terminalizes without submitting the borrowed buffer.
  Keep native synchronous file calls direct; do not imply that the scoped file
  overload is concurrent on a native task until a native completion engine
  exists.
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
- Recursive file watching keeps one bounded registration per real directory,
  with a default capacity of 64. It follows the final root symlink, skips
  nested symlinks, and reconciles registrations after each returned hint.
  Initial overflow is transactional. Later overflow preserves the existing
  registrations and marks coverage incomplete until a complete refresh.
  Directory discovery and registration metadata calls execute on the caller's
  lane; only the readiness wait is task-aware.
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

## Relocatable data-structure invariants

- `Flyology.Data_Structures` stored layouts contain no native address or Ada
  access value. Persist relationships only as fixed-width offsets, indices,
  generations, counters, hashes, and byte payloads; native bases belong only
  to process-local views.
- `Arenas` is generic over a compile-time `Allocation_Algorithms.Contract`
  instance. `flyology_allocators` owns the identity-free algorithm image,
  synchronization, abandonment, and recovery rules; Flyology's adapter owns
  the outer magic, schema, lifecycle, instance identity, and payload-copy
  policy. Arena calls introduce no runtime dispatch or stored callback.
  `Allocation_Algorithms.Buddy`, `Best_Fit`, `TLSF`, and `Slab_Span` adapt the
  standalone out-of-band buddy-tree, in-band AVL best-fit, in-band two-level
  segregated-fit, and out-of-band bitmap-slab/contiguous-span policies.
  Allocation handles contain an opaque fixed-width
  token and nonwrapping generation. Payload access and nested allocation views
  require the handle owner to exclude release.
- `Allocation_Pools.Adaptive` grows a bounded table of arena-backed fixed-size
  slab chunks. Its outer guard covers chunk creation only; published chunks
  retain per-slot slab synchronization. Recovery after abandoned growth must
  reinitialize the backing arena before the pool so old chunk allocations are
  not orphaned.
- `Dynamic.Byte_Strings`, `Dynamic.Vectors`, and `Dynamic.Hash_Maps` are generic
  over an `Arenas` instance. They retain a fixed outer header and replace arena
  allocations during growth. Publish the
  new generation-stamped handle only after copying or rehashing completes, and
  retain the old handle in deferred-reclamation metadata until release
  succeeds. Dynamic means growable within a fixed arena, not mapping growth or
  an unbounded resource guarantee.
- `Vectors`, `Slab_Pools`, both ring leaves, `Hash_Maps`, `Dynamic.Vectors`,
  and `Dynamic.Hash_Maps` are generic over `Storage_Types.Elements` instances.
  An instance binds a definite byte-array value, stable type signature and
  layout version, application source type, and observation type once. Scoped
  read-only references never escape the bound observer; builders are restricted
  to unpublished slots. Attachment validates every adapter identity and
  geometry. `Byte_Strings` and `Dynamic.Byte_Strings` remain concrete byte
  sequences rather than generic element collections.
- Check null sentinels, overflow, alignment, bounds, and complete object extent
  before every native address conversion. Magic, version, schema, geometry,
  initialization state, and mutable indices fail closed on attachment or use.
- Byte strings, vectors, and hash maps use a persisted nonblocking guard plus
  lifecycle poison state and report immediate contention; they never wait or
  retry internally. A dead owner leaves the object locked until an
  independently authorized supervisor poisons it, and exclusive
  reinitialization is the only recovery. Slab allocation, release, read, and
  write use per-slot atomic states and a bounded capacity scan. A dead slab
  owner leaves only its slot transitional; externally authorized recovery must
  poison that slot before explicitly recycling it with a new generation, while
  exclusive whole-pool initialization remains unconditional recovery. SPSC
  permits exactly one producer and one consumer. MPMC uses per-slot sequence
  counters and bounded CAS attempts; an external authority may poison and
  exclusively reinitialize a ring only after establishing participant
  quiescence.
- Fixed and dynamic hash-map attachment must acquire the persisted map guard
  before rereading counts, handles, and probe tables. Never validate mutable
  table contents from the earlier generic-header snapshot.
- Leaf magic/version/schema checks are mandatory. The optional `Envelopes`
  generic adds a stable application-selected 64-bit signature and 64-bit
  contract version without weakening a nested leaf's structural checks.
- `Create_Or_Attach` may atomically claim only an exact zero lifecycle sentinel
  supplied by an allocation protocol that knows the extent is virgin. It never
  overwrites incomplete, destroyed, poisoned, incompatible, or corrupt nonzero
  bytes. It is not recovery because a zeroed corrupt lifecycle is
  indistinguishable from new storage without an outer directory or journal.
- Ring operations are nonblocking and allocate nothing. Keep hot producer and
  consumer counters on separate 64-byte control lines and use power-of-two
  capacities for masked slot selection.
- These packages own no mapping and provide no peer discovery, descriptor
  exchange, wake channel, permissions, flushing, or automatic process-death
  recovery. Slab poison/recycle requires external owner-death and quiescence
  authority.
  Detach every local structure view before releasing its backing mapping.

## Runtime and ABI boundaries

### Native C admission rule

- Ada is the default implementation language. Do not add or expand a native C
  bridge merely because a system API is declared in a C header.
- Prefer direct Ada imports for fixed-signature functions and typed Ada records
  with representation clauses for stable ABI layouts.
- Retain C only when the boundary inherently requires C semantics or tooling,
  such as preprocessor-only constants, compile-time layout assertions, variadic
  calls, opaque foreign callbacks, function-pointer dispatch, or architecture-
  specific compiler intrinsics unavailable from Ada.
- C bridge functions must be narrow mechanisms. They must not own retry logic,
  validation policy, error classification, timeout arithmetic, state machines,
  ownership decisions, cleanup policy, or syscall sequencing that Ada can
  express.
- Header constants and layouts exposed through C should be leaf exports without
  unrelated behavior. Prefer platform Ada specifications when the ABI value is
  stable and independently validated.
- Every new or materially expanded `.c` file requires a repository-grounded
  explanation of why direct Ada import is unsuitable, an audit of which logic
  can instead be SPARK, focused ABI and symbol tests for the retained boundary,
  and a review confirming that no movable policy remains in C.
- When translating an existing bridge, commit the strict behavioral translation
  separately from semantic repairs so each can be reviewed independently.
- Ghost state is not a goal by itself. Use it only when it strengthens a sound
  abstraction; do not mirror asynchronously changing foreign state with an
  unsynchronized ghost model.

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

## Shared-memory segment invariants

- `Flyology.Shared_Memory` owns descriptors and mappings independently. Closing
  a descriptor does not invalidate an established mapping. Detach every leaf,
  region, and segment view before unmapping; finalization is non-raising and
  never implicitly unlinks a named object or file.
- Keep a backing descriptor open through explicit `Unlink`. Callers must
  externally exclude concurrent namespace replacement because identity check
  and unlink are separate operations; Darwin POSIX shm exposes no stable
  per-object identity for that check.
- Anonymous Linux backing has immutable grow/shrink/seal seals and attempts the
  runtime-supported no-execute seal; Darwin anonymous backing is exclusive,
  mode 0600, and immediately unlinked. Public mappings never request execute
  permission or a fixed address.
- Only mappings derived from exclusive backing creation may claim a zero
  segment lifecycle. Opened and received mappings report initialization in
  progress rather than treating abandoned zero bytes as virgin.
- The fixed-capacity segment registry persists exact names, generations,
  geometry, and initializing/ready/failed/removed states. Hash collisions must
  compare complete names. Partial extents are visible only through the limited
  creator claim and become generally resolvable only after publication.
- Validate the mutable allocation frontier and every active or reusable slot's
  generation, name length, aligned location, reservation, payload length, and
  complete extent before allocation, reuse, resolution, or publication.
- Registry removal is distinct from backing-object unlink. Reuse advances a
  nonwrapping generation and may consume only a fitting removed reservation.
  Exhaustion and published initialization failure remain explicit outcomes.
- A dead creator may leave a registry guard or initialization claim abandoned.
  Core never steals it and provides no automatic owner-death recovery. An
  external authority must establish death and quiescence before replacement or
  other recovery.
- Segment growth uses a larger exclusively created virgin replacement mapping,
  never in-place backing resize. The caller must establish quiescence for the
  registry and every nested object. Replacement preserves configuration,
  offsets, generations, reservations, the allocation frontier, and bytes
  through that frontier; it release-publishes the target lifecycle last and
  leaves process-local attachment, handoff, acknowledgment, cutover, and
  old-backing retirement explicit. Successful preparation synchronously zeroes
  and copies bulk bytes while holding the registry guard; use a native-task
  boundary unless event-loop pthread occupation is explicitly acceptable.
- `Shared_Memory.Unix_Sockets.Handoff_Channel` owns a dedicated connected
  `AF_UNIX` `SOCK_STREAM` endpoint for the one-byte, one-`SCM_RIGHTS` protocol.
  No ordinary I/O, duplicate endpoint, or second protocol may share it. Reject
  concurrent use without waiting and poison/close after any operation failure.
  Raw overload callers must enforce the same rules and retire the socket after
  every exception.
- Ancillary receipt scans every bounded control header, accepts exactly one
  descriptor, closes every visible extra, and rejects malformed, unrelated, or
  truncated control data. Linux untrusted receipt also requires a writable,
  exact-size, immutable-size-sealed backing. Reject untrusted receipt on Darwin
  because XNU truncation can install descriptors it does not expose for close.
  Establish CLOEXEC before returning and suppress process-killing SIGPIPE.
- Unix-socket handoff calls are synchronous and require a native-task boundary
  unless readiness was established independently. Send success is only local
  kernel acceptance; socket creation, peer authentication, remote
  acknowledgment, and application trust policy remain outside the package.
- Shared-memory C is an allowlisted ABI leaf boundary: host `stat` extraction,
  variadic `fcntl`, Linux `memfd_create`, socket-family extraction, and one-shot
  `cmsghdr` encoding/decoding only. Ada owns retry, validation, security,
  cleanup, ownership, and lifecycle policy; the pure classifiers are SPARK.
- Backing, mapping, flush, and namespace operations are synchronous metadata or
  VM syscalls and may occupy a lightweight task's event-loop pthread. File
  flush is not a crash-consistent application transaction.

## Repository map

- `src/`: public Flyology packages and platform-neutral API policy.
- `src/platform/{darwin,linux}/`: public-package platform bodies.
- `flyology_cachelines/`: standalone `flyology_cachelines` Alire crate and
  `Flyology_Cachelines` Ada packages for cache-line-aware storage. It does not
  depend on the Flyology runtime and is currently available only on Linux and
  macOS; do not claim or add Windows support without a separately scoped port.
- `flyology_numa/`: standalone `flyology_numa` Alire crate and `Flyology_NUMA`
  Ada packages for memory-node reporting, memory placement, and node-bound
  storage pools. It does not depend on the Flyology runtime and is currently
  available only on Linux and macOS; do not claim or add Windows support
  without a separately scoped port.
- `flyology_allocators/`: standalone `flyology_allocators` Alire crate and
  `Flyology_Allocators` Ada hierarchy. It owns caller-backed allocation
  algorithms, has no Flyology or hosted-OS dependency, and is cross-compiled
  with GNAT 15 `arm-eabi` against the `embedded-stm32f4` bare-board runtime.
- `runtime/ada/`: scheduler, contexts, poller interfaces, and runtime policy.
- `runtime/platform/{darwin,linux}/`: poller and Ada file-engine bodies.
- `runtime/native/`: context-switch assembly and narrow C/OS ABI bridges.
- `runtime/config/`: generated project-default and loop-pool policy templates.
- `runtime/compat/`: GNAT-version ABI adapters.
- `runtime/patches/`: exact GNAT source-context patches; separately licensed.
- `tests/`: behavioral, parity, lifecycle, stress, fault, sanitizer, and
  observability programs.
- `showcases/`: side-by-side demonstrations and reproducible measurements.
- `flyology_debug/`: independent bounded in-memory tracing and gauge crate,
  smoke tests, producer-cost benchmark, and example.
- `flyology_bench/`: independent adaptive and paired-comparison benchmark
  crate, reporters, smoke tests, and examples.
- `proof/`: SPARK-only development crate plus runtime and debug policy proofs.
- `formal/tla/`: bounded TLA+ concurrency models, TLC configurations, and
  reviewed mappings back to production state transitions.
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
- `./scripts/prepare-rts.sh` defaults to `FLYOLOGY_DEFAULT=native`, assembles a
  clean sibling tree, and replaces `build/rts` only after a successful build.
  Applications must compile with `--RTS=<prepared-runtime>`; the public library
  intentionally does not link against stock GNARL by itself.
- A nonempty `FLYOLOGY_RTS_DIR` may be replaced only when it has Flyology's
  `.flyology-rts-root` ownership marker or the recognized complete shape of a
  legacy prepared RTS. Reject project, workspace, home, ancestor, broad,
  symbolic-link, and `..` destinations before assembly. Stage the ownership
  marker in every replacement tree.
- Important preparation controls:
  - `FLYOLOGY_RTS_DIR`: generated RTS destination.
  - `FLYOLOGY_DEFAULT`: `native` or `lightweight`.
  - `FLYOLOGY_LOOP_POOL_SIZE`: prepared fallback and application-startup
    override, `1 .. 128`.
  - `FLYOLOGY_PLACEMENT`: currently `round_robin`.
  - `FLYOLOGY_LOOP_PLACEMENT`: `none`, Linux `strict`, or Darwin `advisory`.
  - `FLYOLOGY_LOOP_PLACEMENT_MAP`: unique `GROUP:VALUE` pairs.
  - `FLYOLOGY_SANITIZER`: `none` or `address`.
  - `FLYOLOGY_TEST_FAULTS` and `FLYOLOGY_TEST_DENY_IO_URING`: test-only `0/1`
    switches; never enable them in a production runtime.
- The loop-pool size is the only application-startup override and is read once.
  The public execution-group API may change the effective automatic-placement
  ceiling later. Other settings are compiled into the prepared RTS and are not
  read dynamically by the application.
- The Alire dependency action reads persisted settings from the ignored
  `build/flyology-rts.conf`. Only an explicit `prepare-alire-rts.sh
  --configure` captures the current `FLYOLOGY_*` settings; ordinary `alr build`
  ignores ambient settings, and `--reset` restores native defaults. Generated
  GPR configuration must bind the validated `gnat_native` or
  `gnat_flyology_native` prefix explicitly.
- Flyology serializes its own Alire RTS preparation within one dependency
  checkout. Alire may still mutate `alire/build_hash_inputs` before dependency
  actions, so concurrent full `alr build` processes must not share one local
  path pin. Use a separate Flyology checkout per build or externally serialize
  the builds.
- Alire redeploys an indexed release into the invoking user's single release
  cache on every command, so two consumers that run at once corrupt each
  other's copy of a shared dependency before any Flyology code runs. A test
  that runs consumers concurrently must sandbox each one with a per-workspace
  `dependencies.shared = false`, which leaves the shared toolchain and index
  folders in place, rather than with `alr -s/--settings=DIR`, which also
  relocates them.
- Treat the Alire RTS input stamp as a transaction commit marker: invalidate it
  before rebuilding, assemble and publish a clean replacement tree, atomically
  publish generated configuration and policy, and publish the replacement
  stamp last.
- Do not commit generated `alire`, `config`, `obj`, `lib`, `build`, `docs/api`,
  test binaries, showcase binaries, or copied GNAT runtime sources.

## Verification

Use the smallest relevant checks while iterating, then run the complete checks
required by the changed boundary.

- `./scripts/test.sh`: authoritative behavioral suite, both project defaults,
  runtime preparation validation, nested standalone-crate tests, and external
  consumer test.
- `./scripts/stress.sh`: bounded deterministic concurrency and fault campaign.
- `FLYOLOGY_LONG_SOAK=1 ./scripts/stress-soak.sh`: opt-in long campaign.
- `./scripts/prove.sh`: authoritative SPARK proof run. All reported checks must
  prove. Never hardcode the total in prose; it changes with contracts.
- `./scripts/check-tla.sh`: bounded TLC checks for extracted concurrency state
  machines plus required counterexamples for deliberately broken variants.
- `./scripts/docs.sh`: GNATdoc HTML generation. It must produce
  `docs/api/index.html` and the nested cachelines and numa APIs with zero
  undocumented-entity warnings or errors.
- `flyology_cachelines/scripts/test.sh`: focused standalone crate suite,
  including native cache queries, representation checks, architecture-spec
  consistency, and compile-fail spill checks.
- `flyology_cachelines/scripts/docs.sh`: standalone cachelines GNATdoc build.
- `flyology_numa/scripts/test.sh`: focused standalone crate suite, covering the
  description reported for the running host and recorded host descriptions that
  the running host does not have.
- `flyology_numa/scripts/multinode-check.sh`: optional non-gating check that
  boots guests with several memory nodes and runs the crate's host suite inside
  them. It needs a Linux host, a kernel image, and qemu, so it is separate from
  `./scripts/test.sh`.
- `flyology_numa/scripts/docs.sh`: standalone numa GNATdoc build.
- `flyology_allocators/scripts/test.sh`: standalone allocator algorithms,
  timed contention, and archive dependency boundary.
- `flyology_allocators/scripts/cross-build.sh`: direct cross build without
  Alire-generated project configuration. The maintained bare-board check uses
  `FLYOLOGY_ALLOCATORS_TARGET=arm-eabi` and
  `FLYOLOGY_ALLOCATORS_RTS=embedded-stm32f4`.
- `cd flyology_allocators/benchmarks && ./scripts/run.sh`: optional hosted
  `flyology_bench` comparison of Buddy, Best-Fit, TLSF, Slab/Span, and native
  `malloc`/`free`. Short settings validate behavior only; use release defaults
  on a quiet host before making performance claims.
- `./scripts/coverage.sh`: GNATcoverage statement and decision baseline for
  Flyology-owned Ada library units. It requires the `gnatcov_bin` tool crate;
  generated traces and reports remain outside version control.
- `./scripts/showcases.sh`: build and run the maintained showcase set. Re-run a
  benchmark before changing a performance table or claim.
- `cd flyology_debug && alr test`: build and run the standalone tracing crate's
  wrap, drop, blocking, automatic and explicit shard selection, merged
  consumption, sharded-producer isolation, batch ownership, borrowed
  visitation, producer state, clear, close, timestamp, sequence, and gauge
  checks.
- `cd flyology_debug && ./scripts/benchmark.sh`: optional non-gating producer
  cost comparison for disabled, injected-clock, automatic-selector,
  native-clock, shared-store, and sharded concurrent tracing. Re-run it before
  making a tracer hot-path performance claim.
- `cd flyology_bench && alr test`: build and run the standalone benchmark
  crate's smoke tests and example, and check the published CSV/JSON schemas.
  Set `FLYOLOGY_BENCH_REQUIRE_PERF=1` to also require Linux hardware counters
  and the inherited worker-task attribution check.
- `./scripts/test-linux-docker.sh`: Linux test on the host’s native architecture.
  It removes the successfully built test image on success or failure. Set
  `FLYOLOGY_KEEP_LINUX_IMAGE=1` only when retaining it for inspection.
  `FLYOLOGY_LINUX_ARCH`, `FLYOLOGY_GNAT_VERSION`,
  `FLYOLOGY_GPRBUILD_VERSION`, and `FLYOLOGY_LINUX_IMAGE` select the target and
  image configuration.
- `FLYOLOGY_LINUX_PERF=1 ./scripts/test-linux-docker.sh`: opt-in Linux run that
  adds Docker `CAP_PERFMON` and requires real PMU samples instead of accepting
  unavailable counters. Run it only where the host exposes a hardware PMU. The
  Apple Virtualization Framework backends used by Docker Desktop and OrbStack
  on Apple Silicon expose none: the guest lists no CPU entry under
  `/sys/bus/event_source/devices`, every `PERF_TYPE_HARDWARE` open returns
  `ENOENT`, and the run correctly fails. Do not weaken the strict mode to make
  such a host pass.
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
- Every CI job and every step that reaches the network carries a
  `timeout-minutes`. Size a new one as a generous multiple of the observed
  healthy duration, read from a recent successful run rather than guessed. The
  bound exists so a stalled mirror or download fails in minutes instead of
  hanging until GitHub's six-hour job default; it is not a performance budget,
  so never tighten one to speed a job up.
- A command that can stall rather than fail needs its own bound inside the
  step, because `timeout-minutes` alone only converts a hang into a late
  failure. `apt-get update` is the known case: cap each attempt with
  `timeout`, retry a stall or transient failure, and keep the worst-case
  budget inside the step bound. Retry only fetches that are safe to repeat;
  let a genuine resolution or install failure surface on the first try.

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
- Hand-written Guide, Architecture, and Journal pages follow `website/AGENTS.md`.
  Link the first explanatory mention of each public Flyology API entity on a
  page to its verified generated GNATdoc unit or declaration entry.
- Runtime specs are maintainer-facing and outside public GNATdoc scope, but
  still need comments for locking, ownership, state transitions, and ABI facts.
- Tests should assert behavior and resource/lifecycle invariants, not merely
  successful exit. For lane parity, compare only outcomes and ordering required
  by Ada—not scheduler traces or wall-clock coincidences.
- Keep test fault injection compiled out of production and isolate expected
  aborts/process exits in subprocesses with timeouts.

## Releases

- Automatic index publication is driven by immutable annotated tags named
  `<crate>/v<version>`, for example `flyology/v0.1.0` or
  `flyology_debug/v0.1.0`.
- Before tagging, change that crate's `alire.toml` from the development
  version to the exact stable version in the tag, replace inappropriate
  `-dev` dependency constraints with stable constraints, and run the crate's
  required validation plus `alr show`. The manifest name and version must
  exactly match the tag's crate and version.
- Never commit a `[[pins]]` entry to a crate manifest here. Alire honours pins
  only in the manifest of the root crate being built, so a committed pin
  reaches this repository's own workspace and no consumer. When a crate pins a
  dependency that its project file imports, the dependency resolves here and is
  absent from every consumer's solution. That failure surfaces at gprbuild as
  `imported project file "<name>.gpr" not found`, not at resolution, so nothing
  in this repository reports it.
- To build against an unpublished change in a sibling crate, pin it in the
  consuming workspace instead:

  ```sh
  alr pin <crate> --use=../<crate-directory>
  ```

  A workspace pin does not travel to consumers. Remove it once the dependency
  is published.
- A dependency declared in a crate manifest must resolve from the index. When a
  nested crate here is a dependency of another crate here, publish it and
  depend on the published version rather than on its path.
- Indexed crates in this repository are `flyology`, `flyology_bench`,
  `flyology_allocators`, `flyology_cachelines`, `flyology_debug`, and
  `flyology_numa`. Tag each released crate independently, even when several
  tags point to one release commit.
- Create and push the tag only after the release-ready manifest is committed:

  ```sh
  git tag -a <crate>/v<version> -m "Release <crate> <version>"
  git push origin refs/tags/<crate>/v<version>
  ```

- Never move, replace, or reuse a published release tag. Make any next
  development-version change in a later commit so the tag continues to identify
  the exact released sources.

## Licensing and commits

- Original code, tests, scripts, proof, and artwork are dual MIT/Apache-2.0.
- `flyology_numa/` is also dual MIT/Apache-2.0.
- `flyology_allocators/` is also dual MIT/Apache-2.0 and carries crate-local
  license copies for standalone publication.
- `flyology_cachelines/` is also dual MIT/Apache-2.0. Preserve its `NOTICE`
  attribution for the spacing policy adapted from Crossbeam.
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
