# HTTP client conformance plan

Flyology does not treat successful requests against a conventional web server
as evidence of HTTP client conformance. The client campaign combines an RFC
requirement ledger, a raw scripted peer, state-model checks, lane parity, TLS
parity, and coverage-guided fuzzing. No single external suite supplies all of
those checks for a general-purpose client API.

## Deterministic ledger

`http_client_smoke.adb` is included in `scripts/test.sh` and currently covers:

| Boundary | Cases |
| --- | --- |
| Shared vocabulary | extensible method tokens, standard method constants, safe/idempotent classification, normalized origins |
| Request wire form | origin-form target, generated Host, ordered repeated fields |
| Pool | bounded admission timeout, idle reuse, abandonment close, new connection after close, coherent counters |
| Response head | repeated fields and an informational response before the final response |
| Message framing | fixed length, chunked decoding, chunk extensions, trailers, and an HTTP/1.0 close-delimited body |
| Task lanes | the same successful exchange sequence from a native caller and an explicitly lightweight caller |

The scripted peer sends literal bytes and does not use `Flyology.HTTP.Server`,
so a shared parser or framing defect cannot make both sides agree incorrectly.

The following rows remain required before describing the client as broadly
HTTP/1.1 conformant:

| Area | Required additions |
| --- | --- |
| Syntax limits | head exactly at and one byte beyond the bound, field-count exhaustion, empty and invalid field names, control bytes, fragmented delimiters |
| Length rules | repeated equal lengths, comma-list variants, decimal overflow, zero length, bodyless HEAD/1xx/204/304 responses with misleading fields |
| Transfer coding | split chunk-size lines, upper/lower hex, size overflow, missing data CRLF, forbidden trailers, incomplete trailer block, unsupported coding chains |
| Persistence | HTTP/1.0 keep-alive, HTTP/1.1 close, stale idle peer, age/request rotation, pruning, shutdown during connect/admission/body read |
| Deadlines | timeout at admission, DNS, connect, TLS handshake, send, head, fixed body, chunk data, and close-delimited body without restarting the clock |
| Cancellation | the same boundaries as deadlines, plus cancellation/shutdown races and exact exception translation |
| Addressing | DNS fallback, IPv4/IPv6 literals, bracketed IPv6 Host, default and explicit ports, all-address failure |
| TLS | verification failure, hostname mismatch, handshake timeout/cancellation, clean and abrupt closure, pool parity with plaintext |
| Resource behavior | descriptor counts after every failure class, abort at each lease transition, client/response finalization ordering |

Each deterministic case should assert both the caller-visible outcome and the
pool/descriptor lifecycle. Timing checks use bounded deadlines only; they do
not assert scheduler traces or exact wall-clock coincidences.

## External scenario sources

The [Dart HTTP client conformance package](https://dart.googlesource.com/http/+/main/pkgs/http_client_conformance_tests/)
is the closest reusable client-oriented design: it starts controlled servers
and applies one behavior suite to multiple client implementations. Its Dart
interface is not a wire-level standard, so Flyology should port applicable
scenarios rather than wrap the Ada API to pretend direct compatibility.

The [curl test suite](https://curl.se/dev/tests-overview.html) supplies a much
larger catalog of protocol, retry, redirect, authentication, proxy, TLS, and
failure cases. Its tests are coupled to curl/libcurl behavior and command-line
features, but they are useful as a coverage inventory.

The [h11 repository](https://github.com/python-hyper/h11) is useful for strict
HTTP/1.1 framing and state-machine cases. It is a protocol engine rather than a
client conformance runner; its malformed-input and connection-state tests are
scenario sources for Flyology's raw peer and parser model.

## Model and fuzz campaigns

The pool controller should also have a deterministic state-model test that
generates checkout, connect success/failure, return, discard, prune, timeout,
and shutdown transitions, then compares every counter and slot phase with a
small reference model. This checks interleavings that a socket scenario may
not reach reliably.

The HTTP head and chunk decoder need a stateless fuzz wrapper accepting a
bounded `Ada.Streams.Stream_Element_Array`, a fragmentation schedule, and a
small expected-body limit. Normal outcomes are a decoded message, a documented
protocol/size exception, or a need-more-data state; assertion failures, range
checks, hangs, and unbounded allocation are crashes. Seeds should include every
deterministic wire case plus boundary-sized heads and chunks.

Run GNATfuzz through Alire when the AdaCore tool is available. Generated
analysis, harness, corpus, and session directories remain build output and must
not be committed. Use an isolated process mode unless the wrapper proves it
resets all parser state between iterations, replay every saved crash, and
record the tool version, seed revision, duration, engines, coverage plateau,
and minimized reproducer. GNATfuzz was not available in the toolchain when this
ledger was introduced, so no fuzz result is claimed here.
