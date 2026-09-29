# Changelog

All notable changes to Flyology will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
[commit 077a964]: https://github.com/flyology-ada/flyology/commit/077a96416bc823c2bf9f4131015489778d8a1151
[commit 112761c]: https://github.com/flyology-ada/flyology/commit/112761c71b6b1d3c8bdbc956b5cc944be8ed2417
[commit 1810fc6]: https://github.com/flyology-ada/flyology/commit/1810fc60ba41bd9029a7d1c96c0e326af1ad415a
[commit 195b228]: https://github.com/flyology-ada/flyology/commit/195b2289cb436a404ea67a7784799be6daa55d6a
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
