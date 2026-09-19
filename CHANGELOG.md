# Changelog

All notable changes to Flyology will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- A lightweight task that reaches a potentially blocking operation inside a
  protected action now raises `Program_Error` at the suspension point and
  releases the lock instead of deadlocking its execution group. Detection
  covers GNARL's existing check sites. `Execution_Groups.Migrate`,
  nonzero-timeout readiness waits, and synchronous lightweight file operations
  likewise refuse before moving the task, parking it, or submitting a buffer.
  Native tasks keep the binder-selected `Detect_Blocking` behavior.
  ([PR #110], [PR #123])
- Lightweight task creation now passes the requested stack size unchanged to
  the guarded-stack allocator; only native stack sizing retains GNARL's
  alternate-stack allowance. Reusable stack arenas are indexed by exact size
  class and sized in whole slots so default-size stacks share mappings, and the
  scheduler releases a finished task's context, guarded stack, and trampoline
  storage after its final switch, including for library-level tasks whose
  control blocks GNARL retains until process finalization. ([PR #233],
  [PR #250], [PR #274])
- On Darwin, `Subprocesses.Spawn` now closes every descriptor in the child
  except the standard streams and explicitly transferred bootstrap
  descriptors, including application descriptors without `FD_CLOEXEC`. On
  Linux, Flyology-created sockets and accepted connections are atomically
  close-on-exec, which closes the window in which a concurrent spawn could
  inherit another task's descriptor. ([PR #271])
- Each spawned root process is now reaped by a detached native thread with its
  own completion state rather than by a library-level Ada task. When hard
  termination fails, `Close` raises promptly and keeps the process owner and
  reaper available for a retry, finalization releases the owner without
  holding Ada shutdown open, and the root is still reaped when descendant
  group cleanup fails. ([PR #278], [PR #298])
- Supervision burst accounting now uses a sliding window. Each recovery account
  retains recent admission times sized from its configured `Burst_Attempts`, so
  failures near a window boundary can no longer admit more than
  `Burst_Attempts` restarts within one `Window`.
  `Supervision_Policy.Restart_Account` gained a `Capacity` discriminant for
  the retained timestamps. ([PR #279])
- Static and family supervisors, their dispatchers, and task-generation
  runners now wait on lifecycle transitions and the nearest readiness, stop,
  recovery, or incident deadline instead of one-millisecond polling timers.
  ([PR #295])
- Fixed and dynamic hash maps now close linear-probe gaps with backward-shift
  deletion instead of retaining tombstones, so probe length no longer depends
  on lifetime inserts. `Table_Full` now means that no empty slot remains, and a
  stored table that contains a tombstone entry is rejected as corrupt.
  ([PR #247])
- A bounded-channel transition now claims one eligible scoped subscriber
  instead of signaling every subscribed completion source; closing a channel
  still notifies all pending operations. Buffer channels and native executors
  deliver subscriber and completion wakes after their protected state
  transitions rather than inside them, and native-executor waits use per-slot
  protected completion gates instead of completion pipes. ([PR #288],
  [PR #301])
- GNARL lane predicates now read an immutable lane flag captured in each task
  control block at creation instead of locking a fiber-registry shard. Warm
  automatic task creation takes the topology lock once, and ordinary reaps take
  it only when a dedicated reservation must be cleared. ([PR #277], [PR #282])
- The Linux poller now keeps registrations in a sparse open-addressed
  descriptor table and retains disabled one-shot records for `EPOLL_CTL_MOD`
  rearm instead of searching linearly and freeing each record after delivery.
  ([PR #260])
- Release stores are now selected by validated compiler family: GNAT 15 and
  later use native Ada atomic stores, while GNAT 13 and stock GNAT 14 use
  fixed-width C leaves. The generated project selection fails closed for an
  unrecognized compiler. ([PR #218], [PR #221])
- The Linux runtime matrix is now architecture-aware.
  `scripts/alire-runtime-matrix.txt` records each compiler cell with its
  published architectures, and the documented support table no longer lists
  stock GNAT 13.2.2 and 14.1.3 for Linux/AArch64, where the configured Alire
  indexes publish no origin. ([PR #259])
- Documented the nonblocking precondition of the immediate socket connect,
  receive, and send overloads and the blocking mode of created sockets, and
  the requirement that a retried TLS driver `Send` presents an identical
  `Data` slice after `Need_Read` or `Need_Write`. ([PR #284], [PR #300])

### Fixed

- Fixed scoped unique-buffer `Send_All` from a later pool slot, which
  transmitted bytes from preceding slots while reporting success. The
  complete-send cursor is now derived from the borrowed slice. ([PR #198])
- Fixed scoped socket operations that retained access values to slice bounds
  in the initiating frame. Initiation now captures the backing address and
  scalar bounds, so retries, readiness, and `Finish` no longer read dead frame
  metadata. ([PR #201])
- Fixed completion-set lifecycle hazards: finalizing a pending operation
  drains through a private target-specific gate and cannot livelock behind an
  unrelated unreported completion, and abort and asynchronous transfer of
  control are deferred across batch dispatch and dependent-gate stabilization
  so a surviving task cannot observe a pending operation with no wait source.
  ([PR #205], [PR #291])
- Fixed failed scoped TLS upgrades that could block or leak cleanup. The
  mandatory close now transfers to the connection through an abort-deferred
  guard, and the last withdrawing peer completes socket, TLS session, and
  admission cleanup exactly once. ([PR #216])
- Fixed scoped `Connect` reporting success for an unconnected socket after a
  shared interrupt wake. The driver confirms writability before reading
  `SO_ERROR` and keeps a Unix backlog retry pending until its timer fires.
  ([PR #294])
- Fixed scoped zero-timeout `File_Watches.Next`, which reported `Timed_Out`
  while change records were still queued in the kernel. ([PR #289])
- Fixed accept cleanup replacing the original timeout, interruption, or socket
  error with a close failure, and closing a caller-owned target that was
  already open on entry. ([PR #296])
- Fixed scoped DNS resolution: an omitted caller deadline keeps the configured
  per-attempt duration instead of expiring every attempt immediately, capacity
  exhaustion when a later driver transition starts a hidden child terminalizes
  the root as `Failed` and closes its temporary sockets, an abandoned TCP
  socket is closed before the next attempt, and the first bare-name failure is
  retained through search expansion. ([PR #199], [PR #232], [PR #290],
  [PR #299])
- Fixed resolver input handling: responses with more than 32 records in a
  section are validated record by record and accepted, unusable search
  suffixes are skipped instead of aborting relative resolution, link-local
  IPv6 name servers with a numeric or named zone are retained, a relative name
  that meets `ndots` is queried bare once per resolution, an overflowing
  synchronous attempt count raises `Resolution_Failed` instead of
  `Constraint_Error`, and DNS sockets are prepared before their immediate
  connect. ([PR #276], [PR #280], [PR #284], [PR #292], [PR #297], [PR #299])
- Fixed subprocess standard-input handling. On Darwin the parent write end
  sets `F_SETNOSIGPIPE`, so writing after the child closes its input raises
  `Pipe_Error` instead of delivering a process-wide fatal `SIGPIPE`, and
  `Subprocesses.Capture.Run` treats `EPIPE` on captured input as input
  completion and still returns the child's status and output. ([PR #202],
  [PR #203])
- Fixed subprocess group signaling that could target a recycled process group.
  The exit observation is recorded before the root is reaped and held while
  `Send_Signal`, `Kill`, `Stop`, and `Close` decide and send a group signal.
  ([PR #272])
- Fixed a guard-page fault on a lightweight task stack terminating the process
  instead of raising `Storage_Error`. Lightweight activation no longer
  reinstalls a per-task alternate signal stack over the one owned by the event
  loop. ([PR #233])
- Fixed children created without a `CPU` aspect by a lightweight task
  inheriting the creator's execution group as a processor. Native children now
  stay unpinned and lightweight children take automatic placement. ([PR #235])
- Kept GNARL's interrupt manager, per-signal server tasks, and
  asynchronous-delay timer server native under a lightweight project default,
  so they neither block an execution group nor start group 0 before the
  application's main subprogram runs. ([PR #245], [commit 1cc1d37])
- Fixed Linux dispatching-domain updates mutating native CPU bookkeeping for a
  lightweight task, where a high execution-group id could index unrelated
  per-CPU state and the affinity hook could pin the event-loop thread shared
  by the whole group. ([PR #266])
- Fixed lost readiness after descriptor reuse. Every new wait re-arms its
  kernel interest instead of trusting an older scheduler link for the same
  descriptor number, and Linux retries `EPOLL_CTL_ADD` when `EPOLL_CTL_MOD`
  reports `ENOENT`. ([PR #243])
- Fixed Linux cancellation of a lightweight descriptor wait by a native abort
  or asynchronous transfer racing the unlocked epoll batch. Cancellation is
  deferred to the owning event loop and drained in one bounded batch at
  scheduler-turn entry, and a queued cancellation owns its wait against
  readiness, timer promotion, dispatch, reuse, and reaping until drained.
  ([PR #258])
- Created Linux epoll instances with `EPOLL_CLOEXEC` so subprocesses no longer
  inherit scheduler descriptors. ([PR #262])
- Fixed deadline handling. Finite readiness timeouts near `Duration'Last`
  saturate instead of wrapping into the no-deadline sentinel, each Darwin
  `kevent` wait slice stays within the accepted range without changing the
  retained deadline, and a Linux lightweight timed sleep whose deadline has
  already passed expires before parking instead of waiting forever.
  ([PR #249], [PR #267])
- Fixed a running lightweight rendezvous acceptor recording head placement
  when it loses inherited priority, which let a later `delay 0.0` bypass an
  already-ready peer of the same priority. ([PR #268])
- Made task and group construction exception-safe. Registry, placement, and
  topology claims are released and partial state is reclaimed when group,
  fiber, or context allocation fails. ([PR #269])
- Fixed scheduler teardown order. Finalization now follows library-object
  finalization in every outcome, including when the binder reraises a saved
  exception. ([PR #261])
- Fixed `Cross_To_Shard` committing a target removed by a concurrent pool
  reduction. The configured-pool target is validated under the topology lock
  at commit and again at physical transfer. ([PR #287])
- Finalizing a `Thread_Pin` owned by a lightweight task from another task now
  raises `Program_Error` instead of silently leaving the owner pinned when
  assertions are disabled. A pin acquired by a native task remains a no-op.
  ([PR #270])
- Fixed native executors declared in the same task master as their workers
  never reaching finalization. Idle workers now wait in a selective accept
  with a terminate alternative. ([PR #239])
- Fixed supervision recovery accounting: readiness is cleared when a
  replacement generation starts so a failed replacement cannot reuse an older
  stability window, a child that terminates during recovery backoff is merged
  into the pending recovery or escalated instead of being left dead, and an
  independent child failure during static recovery is queued for its own
  restart and impact policy instead of ending the node. ([PR #244],
  [PR #248], [PR #293])
- Fixed family supervision lifecycle leaks: a manager failure during a
  replacement publishes and retires the generation actually being run so `Run`
  can finish, `Families.Start` owns its reservation through an abort-safe guard
  so abort or asynchronous transfer before commit returns the capacity, and
  `Stop` accepts a child that was dispatched but has not yet started.
  ([PR #251], [PR #285], [commit 1fa4328])
- Fixed relocatable-structure destruction. Adaptive-pool `Destroy` validates
  every chunk before reclaiming any, so a live slot can no longer leave a
  partially reclaimed pool whose released handles alias later allocations,
  and arena contention during adaptive-pool or dynamic-leaf destruction
  raises `Busy_Error` and stays retryable instead of poisoning coherent state.
  ([PR #234], [PR #236])
- Fixed application observer exceptions poisoning shared structures.
  `Hash_Maps.Get` releases its read guard and an MPMC ring releases the claimed
  slot before propagating the exception; only the claimed ring element is
  lost, and corrupt stored state still poisons. ([PR #238], [PR #275])
- Fixed vector `Attach` and `Create_Or_Attach` reporting live guard contention
  as `Layout_Error`. The stored length is validated under the shared guard,
  and a held guard raises `Busy_Error`. ([PR #281])
- Fixed a stale leaf view writing the guard of an exclusively reused extent.
  Fixed and dynamic guarded leaves and adaptive-pool creation validate the
  cached lifecycle epoch before every guard compare-and-swap. ([PR #286])
- Fixed `Shared_Memory.Security_Properties.No_Execute_Seal_Supported` mirroring
  the inspected descriptor's seal. It now reports a cached `memfd_create`
  probe of kernel support independently of `F_SEAL_EXEC` on that descriptor.
  ([PR #283])
- Restored runtime preparation and builds on GNAT 13.2.2: scoped an exact
  suppression for a spurious `Inline_Always` contract warning, routed release
  stores through C leaves that GNAT 13 can link, and selected a task-attribute
  ABI adapter for GNAT 13's `Atomic_Address` representation. ([PR #207],
  [PR #218], [PR #227])
- Fixed runtime preparation publishing an unpatched RTS when a Flyology path
  pin is nested below another Git worktree. Patches are applied in non-index
  mode and verified by their postconditions, and a stamp-bound content manifest
  of the patched sources and archive members rejects incomplete or changed
  reuse. ([PR #229])
- Compiled patched upstream GNARL units with the upstream runtime assertion
  policy while keeping checked compilation for Flyology-owned runtime units.
  An internal assertion could otherwise escape with activation locks held
  when pthread creation rejected a native task's CPU affinity, deadlocking the
  activator instead of raising `Tasking_Error`. ([PR #237])

## [0.2.0] - 2026-09-01

### Added

- Added bounded completion sets, generation-stamped operation references,
  threshold wait gates, typed `Finish` and `Consume`, and public operation
  continuations. Owner-driven scoped operations compose without helper tasks,
  callback threads, or nested completion-set waits, while the synchronous APIs
  remain available. ([PR #60], [commit df4d183], [commit ed0d6fa])
- Added scoped raw-socket operations for stream and datagram arrays, Internet
  and Unix-stream connection attempts, and accepts. Datagram completion retains
  address, truncation, and ECN metadata, while accept completion retains the
  accepted descriptor until typed `Finish` transfers ownership. ([PR #60],
  [commit 7c4b252], [commit 28b228b], [commit 112761c], [commit e0ab187])
- Added scoped positional file operations with completion-driven submission,
  preserved retry deadlines, bounded queuing under transient kernel pressure,
  and ownership-transferring `Unique_Buffer` overloads. Native synchronous file
  calls remain direct. ([PR #60], [commit 9b8f71e], [commit 69a526a],
  [commit 624d33c])
- Added scoped nonrecursive and recursive file-watcher waits, bounded and buffer
  channel sends and receives, and task-result waits. Pending buffer-channel and
  file operations retain unique ownership until typed completion or drained
  cancellation. ([PR #60], [commit cad92a7], [commit 077a964],
  [commit 66896e6], [commit d01d358])
- Added scoped high-level connection reads, writes, TLS upgrades, and standalone
  TLS handshake, data, and shutdown operations. Set-independent driver
  capabilities let runtime-selected connection and TLS providers participate
  in one parent operation without retaining completion-set access. ([PR #60],
  [commit 7b1e6b5], [commit 3760634], [commit 1810fc6], [commit 195b228])
- Added supervised process-generation upgrades with bounded coordinator and
  agent protocols, descriptor handoff, explicit bootstrap state, readiness
  acknowledgment, rollback, and retirement of the previous generation.
  ([PR #61], [commit c9ccf71])
- Added direct and scoped construction of managed client connections, including
  Internet and Unix-stream attempts that join an existing completion set.
  ([PR #70], [PR #72])
- Added scoped DNS resolution and expanded the transport driver boundary to
  compose up to six descriptor interests, including outbound, lifecycle, and
  caller-borrowed wake sources. ([PR #75], [PR #76])
- Added per-group event-loop utilization snapshots measured on the idle path,
  including an in-progress poller wait in a snapshot without adding clock reads
  to dispatch or context-switch paths. ([PR #50], [commit ae5b52d])
- Added abort-safe heterogeneous buffer domains for runtime-selected pools,
  generation-stamped ownership, domain-bound release tokens, and capability
  publication for remoting sessions. ([PR #83], [PR #84])
- Added prepared supervision-family admissions and generation-exact lifecycle
  observation. Callers can reserve admission and observation capacity before
  task publication, inspect the reserved handle before commit, cancel an exact
  replacement, and retain final-join authority across abort-safe cleanup.
  ([PR #85], [PR #86], [PR #90])

### Changed

- Extracted the allocator implementations into the standalone
  `flyology_allocators` crate and adapted Flyology arenas to its compile-time
  contract. Buddy, best-fit, and TLSF now retain reusable structure lazily, and
  the available policies now include a bitmap slab/contiguous-span allocator.
  Existing arena instantiations must supply the external allocator contract.
  ([PR #37], [PR #37 commits])
- Added exact support for `gnat_flyology_native` 16.2.0-patchset.1.1.0 on macOS
  and Linux while retaining fail-closed validation for unsupported compiler and
  host combinations. The documentation build now fails when GNATdoc dependency
  analysis fails. ([PR #82])

### Fixed

- Retired a unique-buffer pool slot when its nonwrapping generation is
  exhausted, preventing the slot from reentering the free pool with an invalid
  ownership generation. ([PR #83], [commit 86f831c])
- Made bounded-channel send acceptance abort-stable by publishing acceptance
  evidence inside the protected operation before an abort can reclaim or reuse
  the accepted value, and rejected stale acceptance evidence after another
  caller enters the protected operation. ([PR #91], [commit d9f1814],
  [commit 2b6a7ca])

## [0.1.0] - 2026-08-14

### Added

- Initial release.

[Unreleased]: https://github.com/flyology-ada/flyology/compare/flyology/v0.2.0...HEAD
[0.2.0]: https://github.com/flyology-ada/flyology/compare/flyology/v0.1.0...flyology/v0.2.0
[0.1.0]: https://github.com/flyology-ada/flyology/commit/8e0461080e0f110b3bf70dbff283af9ca5e53a2c
[PR #37]: https://github.com/flyology-ada/flyology/pull/37
[PR #37 commits]: https://github.com/flyology-ada/flyology/compare/aa8b12ed09275c855423c99b76404c9e70e27ed0...9a24bf6849e172c6cd030d3df16e9c24b87fbd74
[PR #50]: https://github.com/flyology-ada/flyology/pull/50
[PR #60]: https://github.com/flyology-ada/flyology/pull/60
[PR #61]: https://github.com/flyology-ada/flyology/pull/61
[PR #70]: https://github.com/flyology-ada/flyology/pull/70
[PR #72]: https://github.com/flyology-ada/flyology/pull/72
[PR #75]: https://github.com/flyology-ada/flyology/pull/75
[PR #76]: https://github.com/flyology-ada/flyology/pull/76
[PR #82]: https://github.com/flyology-ada/flyology/pull/82
[PR #83]: https://github.com/flyology-ada/flyology/pull/83
[PR #84]: https://github.com/flyology-ada/flyology/pull/84
[PR #85]: https://github.com/flyology-ada/flyology/pull/85
[PR #86]: https://github.com/flyology-ada/flyology/pull/86
[PR #90]: https://github.com/flyology-ada/flyology/pull/90
[PR #91]: https://github.com/flyology-ada/flyology/pull/91
[PR #110]: https://github.com/flyology-ada/flyology/pull/110
[PR #123]: https://github.com/flyology-ada/flyology/pull/123
[PR #198]: https://github.com/flyology-ada/flyology/pull/198
[PR #199]: https://github.com/flyology-ada/flyology/pull/199
[PR #201]: https://github.com/flyology-ada/flyology/pull/201
[PR #202]: https://github.com/flyology-ada/flyology/pull/202
[PR #203]: https://github.com/flyology-ada/flyology/pull/203
[PR #205]: https://github.com/flyology-ada/flyology/pull/205
[PR #207]: https://github.com/flyology-ada/flyology/pull/207
[PR #216]: https://github.com/flyology-ada/flyology/pull/216
[PR #218]: https://github.com/flyology-ada/flyology/pull/218
[PR #221]: https://github.com/flyology-ada/flyology/pull/221
[PR #227]: https://github.com/flyology-ada/flyology/pull/227
[PR #229]: https://github.com/flyology-ada/flyology/pull/229
[PR #232]: https://github.com/flyology-ada/flyology/pull/232
[PR #233]: https://github.com/flyology-ada/flyology/pull/233
[PR #234]: https://github.com/flyology-ada/flyology/pull/234
[PR #235]: https://github.com/flyology-ada/flyology/pull/235
[PR #236]: https://github.com/flyology-ada/flyology/pull/236
[PR #237]: https://github.com/flyology-ada/flyology/pull/237
[PR #238]: https://github.com/flyology-ada/flyology/pull/238
[PR #239]: https://github.com/flyology-ada/flyology/pull/239
[PR #243]: https://github.com/flyology-ada/flyology/pull/243
[PR #244]: https://github.com/flyology-ada/flyology/pull/244
[PR #245]: https://github.com/flyology-ada/flyology/pull/245
[PR #247]: https://github.com/flyology-ada/flyology/pull/247
[PR #248]: https://github.com/flyology-ada/flyology/pull/248
[PR #249]: https://github.com/flyology-ada/flyology/pull/249
[PR #250]: https://github.com/flyology-ada/flyology/pull/250
[PR #251]: https://github.com/flyology-ada/flyology/pull/251
[PR #258]: https://github.com/flyology-ada/flyology/pull/258
[PR #259]: https://github.com/flyology-ada/flyology/pull/259
[PR #260]: https://github.com/flyology-ada/flyology/pull/260
[PR #261]: https://github.com/flyology-ada/flyology/pull/261
[PR #262]: https://github.com/flyology-ada/flyology/pull/262
[PR #266]: https://github.com/flyology-ada/flyology/pull/266
[PR #267]: https://github.com/flyology-ada/flyology/pull/267
[PR #268]: https://github.com/flyology-ada/flyology/pull/268
[PR #269]: https://github.com/flyology-ada/flyology/pull/269
[PR #270]: https://github.com/flyology-ada/flyology/pull/270
[PR #271]: https://github.com/flyology-ada/flyology/pull/271
[PR #272]: https://github.com/flyology-ada/flyology/pull/272
[PR #274]: https://github.com/flyology-ada/flyology/pull/274
[PR #275]: https://github.com/flyology-ada/flyology/pull/275
[PR #276]: https://github.com/flyology-ada/flyology/pull/276
[PR #277]: https://github.com/flyology-ada/flyology/pull/277
[PR #278]: https://github.com/flyology-ada/flyology/pull/278
[PR #279]: https://github.com/flyology-ada/flyology/pull/279
[PR #280]: https://github.com/flyology-ada/flyology/pull/280
[PR #281]: https://github.com/flyology-ada/flyology/pull/281
[PR #282]: https://github.com/flyology-ada/flyology/pull/282
[PR #283]: https://github.com/flyology-ada/flyology/pull/283
[PR #284]: https://github.com/flyology-ada/flyology/pull/284
[PR #285]: https://github.com/flyology-ada/flyology/pull/285
[PR #286]: https://github.com/flyology-ada/flyology/pull/286
[PR #287]: https://github.com/flyology-ada/flyology/pull/287
[PR #288]: https://github.com/flyology-ada/flyology/pull/288
[PR #289]: https://github.com/flyology-ada/flyology/pull/289
[PR #290]: https://github.com/flyology-ada/flyology/pull/290
[PR #291]: https://github.com/flyology-ada/flyology/pull/291
[PR #292]: https://github.com/flyology-ada/flyology/pull/292
[PR #293]: https://github.com/flyology-ada/flyology/pull/293
[PR #294]: https://github.com/flyology-ada/flyology/pull/294
[PR #295]: https://github.com/flyology-ada/flyology/pull/295
[PR #296]: https://github.com/flyology-ada/flyology/pull/296
[PR #297]: https://github.com/flyology-ada/flyology/pull/297
[PR #298]: https://github.com/flyology-ada/flyology/pull/298
[PR #299]: https://github.com/flyology-ada/flyology/pull/299
[PR #300]: https://github.com/flyology-ada/flyology/pull/300
[PR #301]: https://github.com/flyology-ada/flyology/pull/301
[commit 077a964]: https://github.com/flyology-ada/flyology/commit/077a96416bc823c2bf9f4131015489778d8a1151
[commit 112761c]: https://github.com/flyology-ada/flyology/commit/112761c71b6b1d3c8bdbc956b5cc944be8ed2417
[commit 1810fc6]: https://github.com/flyology-ada/flyology/commit/1810fc60ba41bd9029a7d1c96c0e326af1ad415a
[commit 195b228]: https://github.com/flyology-ada/flyology/commit/195b2289cb436a404ea67a7784799be6daa55d6a
[commit 1cc1d37]: https://github.com/flyology-ada/flyology/commit/1cc1d378f02c65896a7d54c76c82c585101910b3
[commit 1fa4328]: https://github.com/flyology-ada/flyology/commit/1fa4328ec180a7e401a0f45c37657e81311a8d5f
[commit 28b228b]: https://github.com/flyology-ada/flyology/commit/28b228bb9ea8b496a8ef998a15f6a955700033af
[commit 2b6a7ca]: https://github.com/flyology-ada/flyology/commit/2b6a7caddf63a89699b84018e6cc4a015b40d18b
[commit 3760634]: https://github.com/flyology-ada/flyology/commit/3760634bfb9ad77ced917756aac362db2a466aab
[commit 624d33c]: https://github.com/flyology-ada/flyology/commit/624d33c57e1e16df0a1655caab1368ee10128ca5
[commit 66896e6]: https://github.com/flyology-ada/flyology/commit/66896e62279ab4f677db17b028d33ffb732443a0
[commit 69a526a]: https://github.com/flyology-ada/flyology/commit/69a526a82848367d1723c7b00f58c34c82150cdc
[commit 7b1e6b5]: https://github.com/flyology-ada/flyology/commit/7b1e6b588e23ff3dc2e3ff62bffefd06af53fe01
[commit 7c4b252]: https://github.com/flyology-ada/flyology/commit/7c4b252374ac31cdd58edbe7d6d0a95e29d29e42
[commit 86f831c]: https://github.com/flyology-ada/flyology/commit/86f831cce5ba8676f5471491da3a3ce710174791
[commit 9b8f71e]: https://github.com/flyology-ada/flyology/commit/9b8f71e86e699c9871b8b4d51f9449a3a97f7f40
[commit ae5b52d]: https://github.com/flyology-ada/flyology/commit/ae5b52d7c57dd874139d7e5846d90f2ce1c7ff66
[commit c9ccf71]: https://github.com/flyology-ada/flyology/commit/c9ccf71bb483b2abeb060b918fb2ff639cf67e18
[commit cad92a7]: https://github.com/flyology-ada/flyology/commit/cad92a77e1902bf7b51f025d96b5300aeeb8f5df
[commit d01d358]: https://github.com/flyology-ada/flyology/commit/d01d358da5186df0aceba44855aefc2131ec7dac
[commit d9f1814]: https://github.com/flyology-ada/flyology/commit/d9f181441ddb0c701ca7d32891b721a62253e2b5
[commit df4d183]: https://github.com/flyology-ada/flyology/commit/df4d183758b2d67530e2a2b2e4963164922d4a15
[commit e0ab187]: https://github.com/flyology-ada/flyology/commit/e0ab1878efc5c00f01dd546642d849a218640b85
[commit ed0d6fa]: https://github.com/flyology-ada/flyology/commit/ed0d6fa9e63b1d03efee2bcfbda7e87ecee40438
