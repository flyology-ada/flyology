# Changelog

All notable changes to Flyology Allocators will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- The metadata release store is now selected by validated compiler family.
  GNAT 15 and later use a native Ada atomic store, while GNAT 13 and stock
  GNAT 14 use one fixed-width 32-bit C leaf with a compile-time release
  ordering. An Alire pre-build action and `scripts/cross-build.sh` run
  `scripts/configure-atomic-store-family.sh`, which generates the private
  project selection from the exact compiler release and rejects an
  unrecognized one. A direct `gprbuild` must run that script first, and a
  GNAT 13 or 14 build now also compiles C. ([PR #221])

### Fixed

- Fixed unresolved `__atomic_store_n` references when linking archives built
  with GNAT 13.2.2, which cannot lower an Ada intrinsic import of that generic
  builtin. ([PR #218])

## [0.1.0] - 2026-09-01

### Added

- Added caller-owned arenas over explicit address-and-extent regions. Stored
  allocator images contain fixed-width offsets, counters, generations,
  geometry, and bookkeeping without native addresses, callbacks, application
  magic, or schema policy. ([PR #37], [PR #37 commits])
- Added compile-time-selected Buddy, Best-Fit, TLSF, and Slab/Span allocation
  algorithms. Buddy, Best-Fit, and TLSF retain reusable free structure lazily
  and perform a bounded rebuilding pass before reporting exhaustion; Slab/Span
  combines bitmap small-object classes with contiguous fixed-run spans.
  ([PR #37], [PR #37 commits])
- Added immediate allocation and release operations that report metadata
  contention without waiting, plus monotonic-deadline timed operations that
  yield with `delay 0.0` between bounded attempts. ([PR #37],
  [PR #37 commits])
- Added a standalone project and Alire crate with no Flyology runtime, event
  loop, shared-memory, mapping-provider, or hosted operating-system dependency,
  including native verification and the documented GNAT bare-board cross-build
  profile. ([PR #37], [PR #37 commits])

[Unreleased]: https://github.com/flyology-ada/flyology/compare/flyology_allocators/v0.1.0...HEAD
[0.1.0]: https://github.com/flyology-ada/flyology/compare/aa8b12ed09275c855423c99b76404c9e70e27ed0...flyology_allocators/v0.1.0
[PR #37]: https://github.com/flyology-ada/flyology/pull/37
[PR #37 commits]: https://github.com/flyology-ada/flyology/compare/aa8b12ed09275c855423c99b76404c9e70e27ed0...9a24bf6849e172c6cd030d3df16e9c24b87fbd74
[PR #218]: https://github.com/flyology-ada/flyology/pull/218
[PR #221]: https://github.com/flyology-ada/flyology/pull/221
