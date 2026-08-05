# WebSocket conformance report — 2026-08-04

Flyology's server-side RFC 6455 implementation was exercised with the official
[Autobahn Testsuite](https://github.com/crossbario/autobahn-testsuite), release
25.10.1. The immutable container image digest was
`sha256:519915fb568b04c9383f70a1c405ae3ff44ab9e35835b085239c258b6fac3074`.
The implementation under test is repository revision `c4f1dd4`, tested on
Darwin/AArch64 with GNAT 16.1.0. The complete 14-profile harness and published
report first exist together at revision `9428106`. That later snapshot added
the native limits profile, native Core over WSS, and the lightweight and native
WSS timing profiles. The two revisions have byte-identical `src/` and
`runtime/` trees and the same `websocket_conformance_server` source blob.

The runner did not record a checkout revision for each historical invocation,
so neither revision is presented as a recovered per-run SHA. `c4f1dd4`
identifies the implementation bytes exercised by the campaign; `9428106`
identifies the first complete harness/report snapshot that retains all 14
published profiles.

## Result

The RFC-focused profile reported no failures in either execution lane or when
repeated through Flyology's OpenSSL-backed WSS transport:

| Lane and transport | Cases | OK | Non-strict | Informational | Failed |
| --- | ---: | ---: | ---: | ---: | ---: |
| Lightweight task, `ws://` | 247 | 240 | 4 | 3 | 0 |
| Native task, `ws://` | 247 | 240 | 4 | 3 | 0 |
| Lightweight task, `wss://` | 247 | 240 | 4 | 3 | 0 |
| Native task, `wss://` | 247 | 240 | 4 | 3 | 0 |

All close-behavior checks were `OK` except for the same three informational
cases. All four lane/transport results were identical. The WSS adapter completed
Flyology's nonblocking server handshake with OpenSSL 3.6.3 before passing the
connection to the same public HTTP and WebSocket handler used by the plaintext
profiles.

The four `NON-STRICT` results were cases 6.4.1–6.4.4. Flyology rejects invalid
UTF-8 when the complete fragmented message is available rather than at the
first fragment that makes the eventual sequence invalid. Autobahn lists both
timings as acceptable; the connection still closed with code 1007.

The informational results were 7.1.6, whose back-to-back data/close ordering is
implementation-defined, and 7.13.1–7.13.2, which use close codes outside the
RFC-defined range. They are not conformance failures.

## Limits profile

Autobahn's section 9.1–9.6 size and chunking family was run through both task
lanes with `Max_Message` explicitly set to Flyology's supported 16 MiB maximum:

| Lane | Cases | OK | Failed |
| --- | ---: | ---: | ---: |
| Lightweight task | 42 | 42 | 0 |
| Native task | 42 | 42 | 0 |

Every text, binary, fragmented, and chopped-delivery case from 64 KiB through
16 MiB passed. Flyology retains a 1 MiB default for ordinary calls; applications
opt into a larger `Max_Message` when their ingress budget and workload justify
it. The large-frame path moves masking and echo writes through bounded chunks,
so the configured message limit does not become a task-stack allocation.

## Compression profile

Autobahn sections 12 and 13 were run through both execution lanes over both
plaintext and OpenSSL-backed WSS, with the adapter explicitly enabling RFC 7692
`permessage-deflate`:

| Lane and transport | Cases | Message exchanges | OK | Failed |
| --- | ---: | ---: | ---: | ---: |
| Lightweight task, `ws://` | 216 | 216,000 | 216 | 0 |
| Native task, `ws://` | 216 | 216,000 | 216 | 0 |
| Lightweight task, `wss://` | 216 | 216,000 | 216 | 0 |
| Native task, `wss://` | 216 | 216,000 | 216 | 0 |

All behavior and close verdicts were `OK`. The profile covers compressed text
and binary data, fragmentation, payload sizes from 16 through 131,072 bytes,
and seven client offer/server-response combinations for context takeover and
window bits.

Flyology's opt-in policy responds with no context takeover in both directions.
Its bounded pure-Ada decoder accepts stored, fixed-Huffman, and dynamic-Huffman
raw DEFLATE blocks and applies the configured message and shared ingress limits
to decompressed output. The deterministic outbound encoder uses a bounded LZ77
search and fixed Huffman coding, falling back to literals when no match is
useful. A direct regression check verifies that a repetitive 256-byte message
is smaller on the wire. Messages larger than 4 KiB are selectively sent
uncompressed to bound event-loop CPU, as RFC 7692 permits.

The local behavioral suite also applies 576 deterministic adversarial inputs:
known-valid streams, all one-byte values, structured prefixes, truncations, and
every single-bit mutation of a valid stream. Each must either decode within the
configured output limit or fail with WebSocket close code 1007/1009; runtime
check failures are rejected. GNATfuzz was not available in the installed Alire
toolchain, so this is a repeatable mutation corpus rather than a
coverage-guided fuzzing campaign.

## Performance profile

Autobahn's section 9.7–9.8 echo timing family was recorded separately through
both execution lanes over WS and WSS:

| Lane and transport | Cases | Round trips | OK | Failed | Case-duration range |
| --- | ---: | ---: | ---: | ---: | ---: |
| Lightweight task, `ws://` | 12 | 12,000 | 12 | 0 | 113–271 ms |
| Native task, `ws://` | 12 | 12,000 | 12 | 0 | 113–291 ms |
| Lightweight task, `wss://` | 12 | 12,000 | 12 | 0 | 163–366 ms |
| Native task, `wss://` | 12 | 12,000 | 12 | 0 | 167–443 ms |

Each case sends 1,000 sequential text or binary messages at one of six payload
sizes from 0 through 4,096 bytes. The published profile retains Autobahn's total
case duration and shows derived mean round-trip time and echo rate on a separate
page for each lane/transport variation. The runner verifies Alire's generated
`release` profile, requires its `-O3` switch, explicitly compiles the standalone
Autobahn harness with `-O3`, and writes that evidence beside the raw results.
The publisher refuses performance input without this release record. These are
single-host loopback observations that include case setup and close work, not
portable performance guarantees, pass/fail thresholds, or evidence of a
general performance ordering between lanes or transports.

The timing observation was recorded on this equipment:

| Item | Recorded value |
| --- | --- |
| Host | MacBook Pro (Mac15,9) |
| Processor | Apple M3 Max, 16 cores (12 performance, 4 efficiency) |
| Memory | 48 GB |
| System | macOS 26.5.2 (25F84), arm64 |
| Toolchain | GNAT 16.1.0, Alire 2.1.1 |
| Build | Alire release; `-O3` library and harness |
| Test client | Autobahn 25.10.1 `linux/amd64` container on the same host |

This equipment record supports like-for-like regression comparison. It does not
turn one loopback run into a cross-machine benchmark.

## Scope and boundaries

The core profile includes every non-performance, non-compression server case
selected by this Autobahn release: case families 1–7 and 10. Section 9 limits
and timing are reported separately above. Sections 12 and 13 exercise the
optional RFC 7692 `permessage-deflate` extension and are reported in the
compression profile.

The core run tested `ws://` framing, fragmentation, control frames, close
handling, masking enforcement, lengths, and UTF-8 behavior, then repeated the
same cases over `wss://` in both lanes. The TLS campaign used the repository's
deterministic
self-signed fixture and Autobahn's local fuzzing client without hostname
verification; it exercises secure transport integration and WebSocket behavior,
not public-key infrastructure policy. Compression was repeated over both
`ws://` and `wss://`, and acceptance remains bounded by the supported 16 MiB
maximum. The default message limit remains 1 MiB.

Flyology currently exposes a WebSocket server API, not a WebSocket client API,
so Autobahn's client-under-test role is outside the implemented surface rather
than an unrun server conformance case family.

## Reproduction

The checked-in adapter uses only Flyology's public HTTP, WebSocket, connection,
and TLS APIs. Docker must support host networking; the pinned Autobahn image
runs as `linux/amd64`. WSS profiles require
`FLYOLOGY_OPENSSL_LIBRARY_DIR` to name one OpenSSL 3 installation containing
the matched `libssl` and `libcrypto` modules; the runner hashes those exact
files and validates the provider name and version reported by the server.

```sh
./scripts/websocket-conformance.sh core lightweight
./scripts/websocket-conformance.sh core native
./scripts/websocket-conformance.sh core-wss lightweight
./scripts/websocket-conformance.sh core-wss native
./scripts/websocket-conformance.sh limits lightweight
./scripts/websocket-conformance.sh limits native
./scripts/websocket-conformance.sh compression lightweight
./scripts/websocket-conformance.sh compression native
./scripts/websocket-conformance.sh compression-wss lightweight
./scripts/websocket-conformance.sh compression-wss native
./scripts/websocket-conformance.sh performance lightweight
./scripts/websocket-conformance.sh performance native
./scripts/websocket-conformance.sh performance-wss lightweight
./scripts/websocket-conformance.sh performance-wss native
```

Each invocation writes Autobahn's HTML and per-case JSON reports under
`build/autobahn/`. Before building, it writes a non-publishable initial source
snapshot. Only after the verdict gate passes does it recapture the full Git
HEAD and tree, clean tracked/untracked status, submodule state, branch or
detached-worktree identity, and profile-config hash. Any change prevents final
metadata from being written. The final `run-metadata.json` also records the
observed OS, architecture, CPU, memory, exact GNAT and Alire version strings,
pinned Autobahn image digest and platform, release/-O3 build/runtime settings,
and transport-specific TLS provider, version, module basenames, sizes, and
SHA-256 digests. Hostnames and filesystem paths are intentionally omitted.
Generated reports remain outside version control.

To regenerate the compact, restyled pages committed under `website/reports`,
run:

```sh
node scripts/publish-websocket-conformance.mjs
```

The publisher requires valid metadata for every profile and rejects dirty,
profile-mismatched, or cross-run-inconsistent inputs before replacing the
checked-in report bundle. Source, sanitized host facts, toolchain, image, and
build settings must match across all profiles; profile/config, capture time,
lane, and transport may differ, while TLS identity must match across WSS
profiles and is absent from plaintext profiles. Publication renders and checks
the complete file, JSON, and link set in a guarded sibling staging directory.
An atomic sibling lock serializes recovery, rendering, commit, and quarantine
cleanup for one output bundle. Its owner record contains only a schema, output
basename, PID, UTC start time, random nonce, and process-start identity. A
second publisher must retry after the live owner exits. A well-formed lock is
recovered automatically only when its PID is gone or an observable process
start proves PID reuse; an unobservable live PID is treated as active, while a
malformed or symlinked lock requires inspection and removal of that exact lock
directory by an operator.

The verified stage-to-live rename is the publication commit point. Before it,
rollback restores only a backup matching the transaction fingerprint. After
it, the publisher re-verifies the renamed live bundle and moves the old bundle
to a non-rollback quarantine; cleanup failure cannot replace the new live tree
with a partially deleted backup. The lock remains owned through that cleanup,
and every shared stage, transaction, backup, and quarantine rename or removal
checks the same owner nonce first. The 2026-08-04 raw outputs predate the
metadata schema, so this historical report preserves the implementation and
complete harness/report snapshots above rather than inventing per-run
revisions.

The published report is available at
[flyology.org/reports/websocket](https://flyology.org/reports/websocket/).
