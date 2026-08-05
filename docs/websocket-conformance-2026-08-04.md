# WebSocket conformance report — 2026-08-04

Flyology's server-side RFC 6455 implementation was exercised with the official
[Autobahn Testsuite](https://github.com/crossbario/autobahn-testsuite), release
25.10.1. The immutable container image digest was
`sha256:519915fb568b04c9383f70a1c405ae3ff44ab9e35835b085239c258b6fac3074`.
The code under test was repository revision `7880b4e`, plus the test adapter
recorded with this report, on Darwin/AArch64 with GNAT 16.1.0.

## Result

The RFC-focused profile reported no failures in either execution lane or when
repeated through Flyology's OpenSSL-backed WSS transport:

| Lane and transport | Cases | OK | Non-strict | Informational | Failed |
| --- | ---: | ---: | ---: | ---: | ---: |
| Lightweight task, `ws://` | 247 | 240 | 4 | 3 | 0 |
| Native task, `ws://` | 247 | 240 | 4 | 3 | 0 |
| Lightweight task, `wss://` | 247 | 240 | 4 | 3 | 0 |

All close-behavior checks were `OK` except for the same three informational
cases. The plaintext lightweight, plaintext native, and WSS lightweight results
were identical. The WSS adapter completed Flyology's nonblocking server
handshake with OpenSSL 3.6.3 before passing the connection to the same public
HTTP and WebSocket handler used by the plaintext profiles.

The four `NON-STRICT` results were cases 6.4.1–6.4.4. Flyology rejects invalid
UTF-8 when the complete fragmented message is available rather than at the
first fragment that makes the eventual sequence invalid. Autobahn lists both
timings as acceptable; the connection still closed with code 1007.

The informational results were 7.1.6, whose back-to-back data/close ordering is
implementation-defined, and 7.13.1–7.13.2, which use close codes outside the
RFC-defined range. They are not conformance failures.

## Limits profile

Autobahn's section 9.1–9.6 size and chunking family was run through the
lightweight lane with `Max_Message` explicitly set to Flyology's supported
16 MiB maximum:

| Cases | OK | Failed |
| ---: | ---: | ---: |
| 42 | 42 | 0 |

Every text, binary, fragmented, and chopped-delivery case from 64 KiB through
16 MiB passed. Flyology retains a 1 MiB default for ordinary calls; applications
opt into a larger `Max_Message` when their ingress budget and workload justify
it. The large-frame path moves masking and echo writes through bounded chunks,
so the configured message limit does not become a task-stack allocation.

## Performance profile

Autobahn's section 9.7–9.8 echo timing family was recorded separately through
both execution lanes:

| Lane | Cases | Round trips | OK | Failed | Case-duration range |
| --- | ---: | ---: | ---: | ---: | ---: |
| Lightweight task | 12 | 12,000 | 12 | 0 | 113–350 ms |
| Native task | 12 | 12,000 | 12 | 0 | 106–265 ms |

Each case sends 1,000 sequential text or binary messages at one of six payload
sizes from 0 through 4,096 bytes. The published profile retains Autobahn's total
case duration and shows derived mean round-trip time and echo rate on a separate
page for each lane. These are single-host loopback observations that include
case setup and close work, not portable performance guarantees, pass/fail
thresholds, or evidence of a general performance ordering between lanes.

The timing observation was recorded on this equipment:

| Item | Recorded value |
| --- | --- |
| Host | MacBook Pro (Mac15,9) |
| Processor | Apple M3 Max, 16 cores (12 performance, 4 efficiency) |
| Memory | 48 GB |
| System | macOS 26.5.2 (25F84), arm64 |
| Toolchain | GNAT 16.1.0, Alire 2.1.1 |
| Test client | Autobahn 25.10.1 `linux/amd64` container on the same host |

This equipment record supports like-for-like regression comparison. It does not
turn one loopback run into a cross-machine benchmark.

## Scope and exclusions

The core profile includes every non-performance, non-compression server case
selected by this Autobahn release: case families 1–7 and 10. Section 9 limits
and timing are reported separately above. Sections 12 and 13 exercise the optional RFC 7692
`permessage-deflate` extension and were excluded because Flyology does not
implement or negotiate that extension.

The core run tested `ws://` framing, fragmentation, control frames, close
handling, masking enforcement, lengths, and UTF-8 behavior, then repeated the
same cases over `wss://`. The TLS campaign used the repository's deterministic
self-signed fixture and Autobahn's local fuzzing client without hostname
verification; it exercises secure transport integration and WebSocket behavior,
not public-key infrastructure policy. This report does not claim WebSocket
compression support or acceptance above the supported 16 MiB bound. The default
message limit remains 1 MiB.

## Reproduction

The checked-in adapter uses only Flyology's public HTTP, WebSocket, connection,
and TLS APIs. Docker must support host networking; the pinned Autobahn image
runs as `linux/amd64`.

```sh
./scripts/websocket-conformance.sh core lightweight
./scripts/websocket-conformance.sh core native
./scripts/websocket-conformance.sh core-wss lightweight
./scripts/websocket-conformance.sh limits lightweight
./scripts/websocket-conformance.sh performance lightweight
./scripts/websocket-conformance.sh performance native
```

Each invocation writes Autobahn's HTML and per-case JSON reports under
`build/autobahn/`. Generated reports remain outside version control.

To regenerate the compact, restyled pages committed under `website/reports`,
run:

```sh
node scripts/publish-websocket-conformance.mjs
```

The published report is available at
[flyology.org/reports/websocket](https://flyology.org/reports/websocket/).
