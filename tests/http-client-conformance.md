# HTTP client conformance plan

Flyology does not treat successful requests against a conventional web server
as evidence of HTTP client conformance. The client campaign combines an RFC
requirement ledger, a raw scripted peer, state-model checks, lane parity, TLS
parity, and coverage-guided fuzzing. No single external suite supplies all of
those checks for a general-purpose client API.

## Deterministic ledger

`scripts/http-client-conformance.sh` builds and runs nine independent programs
plus compile-fail client/response and body-source/payload lifetime fixtures:

| Boundary | Cases |
| --- | --- |
| Shared vocabulary | extensible method tokens, standard method constants, safe/idempotent classification, normalized origins |
| Request wire form | origin-form target, generated Host, ordered repeated fields |
| Request streaming | known-length Content-Length, unknown-length chunked coding, source progress and early-end rejection, source exception cleanup, retained-body conflict, and native/lightweight parity |
| Request body adapters | borrowed arrays with nondefault bounds and explicit rewind, byte strings, owned bytes, unique-buffer ownership retention, positional file ranges, generated channel bodies with known or chunked framing, file timeout, channel timeout/cancellation, backpressure, and lane parity |
| Upload controls | Expect/continue after informational responses, final-response body suppression, bounded continue fallback, request trailer declaration and emission, prohibited trailer rejection, one idempotent rewindable-source stale retry, one-shot non-retry, and lane parity |
| Pool | bounded admission timeout, idle reuse, abandonment close, one stale-idle retry only for idempotent methods, request-count/idle-time/total-age rotation, HTTP/1.0 keep-alive, pruning, shutdown interruption, coherent exchange/transport counters, descriptor restoration |
| Response head | repeated fields, an informational response before the final response, and byte-at-a-time status/header delivery |
| Message framing | fixed length, chunked decoding, chunk extensions, trailers, and an HTTP/1.0 close-delimited body |
| Parser matrix | exact and over-limit heads, field-count exhaustion, invalid names and values, equal and conflicting lengths, decimal/chunk overflow, coding chains, missing delimiters, forbidden/incomplete trailers, and bodyless status rules |
| Parser mutation | 10,000 fixed-seed random and near-valid mutated inputs through the same production parser oracle used by GNATfuzz |
| Deadlines and cancellation | pool admission and response-head deadlines, fixed-body deadline continuity, and call-scoped chunked-body cancellation |
| Task lanes | the same successful, streaming, and boundary exchange sequences from native and explicitly lightweight callers |
| HTTPS | OpenSSL certificate and hostname verification, retained provider state after the original provider finalizes, native/lightweight reuse, mismatch rejection, handshake timeout and cancellation, and descriptor restoration |
| Lifetime | the compiler rejects a response that would escape the aliased client and an adapter that would escape its borrowed payload; runtime shutdown closes and drains active exchanges |

The scripted peer sends literal bytes and does not use `Flyology.HTTP.Server`,
so a shared parser or framing defect cannot make both sides agree incorrectly.

The following rows remain required before describing the client as broadly
HTTP/1.1 conformant:

| Area | Required additions |
| --- | --- |
| Fragmentation | add an instrumented receive cap to prove each delimiter crosses distinct client receive calls; the raw peer already writes every response and chunk/trailer byte separately |
| Length rules | remaining RFC 9110 status/method combinations with misleading framing fields beyond the dedicated HEAD case |
| Persistence | shutdown during DNS/connect and pool admission, plus simultaneous shutdown/return races |
| Deadlines | timeout at DNS, connect, send, chunk data, and close-delimited body; head and fixed-body continuity are covered |
| Cancellation | the remaining DNS/connect/send/fixed/close-delimited boundaries, plus abort and cancellation/shutdown races at every lease transition |
| Addressing | DNS fallback, IPv4/IPv6 literals, bracketed IPv6 Host, default and explicit ports, all-address failure |
| TLS | trust-chain rejection distinct from hostname mismatch, clean/abrupt closure while streaming each body mode, and shutdown during provider setup |
| Resource behavior | descriptor counts after every remaining failure class and abort at each lease transition |

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

`http_client_pool_model.adb` drives the public client through checkout,
successful creation, stale failure, one-time retry, return, request-count
discard, prune, active-read shutdown, and final drain. It compares every
observable exchange/transport counter with its transition table and restores
the process descriptor baseline. Internal-only slot phases are not exposed as
public API; forced abort and simultaneous transition races remain in the table
above.

`Flyology.HTTP.Client.Testing.Fuzz_Response` is a stateless wrapper around the
production status, header, length, chunk, and trailer validators. It accepts a
fixed 1,000-byte array plus a prefix length. Documented protocol and size
rejections are normal outcomes; assertion failures, runtime checks, hangs, and
other exceptions remain crashes. The larger exact-boundary cases stay in the
deterministic parser matrix because GNATfuzz's automatic marshaller limits
array parameters to 1,000 components.

Run `./scripts/http-client-fuzz.sh prepare` through Alire when the AdaCore tool
is available. It analyzes the dedicated wrapper, selects its reported
subprogram id, generates an isolated `afl_plain` harness, builds it, and creates
a starting corpus under ignored `build/gnatfuzz/http-client`. Run
`./scripts/http-client-fuzz.sh fuzz` for the campaign. Replay every saved crash
and record the tool version, seed revision, duration, engines, coverage
plateau, and minimized reproducer. GNATfuzz was not available in the current
toolchain, so no fuzz result is claimed here.
