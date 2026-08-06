# HTTP client conformance plan

Flyology does not treat successful requests against a conventional web server
as evidence of HTTP client conformance. The client campaign combines an RFC
requirement ledger, a raw scripted peer, state-model checks, lane parity, TLS
parity, and coverage-guided fuzzing. No single external suite supplies all of
those checks for a general-purpose client API.

## Deterministic ledger

`scripts/http-client-conformance.sh` builds and runs fourteen independent programs
plus compile-fail client/response and body-source/payload lifetime fixtures:

| Boundary | Cases |
| --- | --- |
| Shared vocabulary | extensible method tokens, standard method constants, safe/idempotent classification, normalized origins |
| Request wire form | origin-form target, generated Host, ordered repeated fields |
| Request streaming | known-length Content-Length, unknown-length chunked coding, source progress and early-end rejection, source exception cleanup, retained-body conflict, and native/lightweight parity |
| Request body adapters | borrowed arrays with nondefault bounds and explicit rewind, byte strings, owned bytes, unique-buffer ownership retention, positional file ranges, generated channel bodies with known or chunked framing, file timeout, channel timeout/cancellation, backpressure, and lane parity |
| Upload controls | Expect/continue after informational responses, final-response body suppression, one-time 417 fallback without Expect, bounded continue fallback, request trailer declaration and emission, prohibited and duplicate trailer rejection, exact known-length completion, one idempotent rewindable-source stale retry, one-shot non-retry, and lane parity |
| Pool | bounded admission timeout, idle reuse, abandonment close, one stale-idle retry only for idempotent methods, request-count/idle-time/total-age rotation, HTTP/1.0 keep-alive, pruning, shutdown interruption, deterministic active-return and abort races, held-lease admission shutdown, idle prune/checkout races, coherent exchange/transport counters, and descriptor restoration |
| Response fragmentation | a one-byte connection receive cap with an exact call count, forcing status-line, header, chunk, data, terminal-chunk, and trailer delimiters across distinct client receive calls in both task lanes |
| Message framing | fixed length, chunked decoding, chunk extensions, trailers, and an HTTP/1.0 close-delimited body |
| RFC response corpus | 42 named accepted and rejected examples covering status syntax, field folding and whitespace, length precedence, informational and bodyless responses, transfer codings, chunk extensions, trailers, and incomplete messages |
| Parser matrix | exact and over-limit heads, field-count exhaustion, invalid names and values, equal and conflicting lengths, decimal/chunk overflow, coding chains, missing delimiters, forbidden/incomplete trailers, and bodyless status rules |
| Parser mutation | 10,000 fixed-seed random and near-valid inputs, rotating all 42 RFC seeds through zero to eight byte mutations and the same production parser oracle used by GNATfuzz |
| Deadlines and cancellation | forced timeout and active call-scoped cancellation at DNS, connect, request send, response head, fixed-length body, chunked body, and close-delimited body boundaries, plus pool-admission timeout |
| Task lanes | the same successful, streaming, and boundary exchange sequences from native and explicitly lightweight callers |
| HTTPS | OpenSSL certificate and hostname verification, retained provider state after the original provider finalizes, native/lightweight reuse, mismatch rejection, handshake timeout and cancellation, orderly and truncating closure during every response body mode, and descriptor restoration |
| Lifetime | the compiler rejects a response that would escape the aliased client and an adapter that would escape its borrowed payload; runtime shutdown closes and drains active exchanges |

The scripted peer sends literal bytes and does not use `Flyology.HTTP.Server`,
so a shared parser or framing defect cannot make both sides agree incorrectly.

The following rows remain required before describing the client as broadly
HTTP/1.1 conformant:

| Area | Required additions |
| --- | --- |
| Length rules | remaining RFC 9110 status/method combinations with misleading framing fields beyond the dedicated HEAD case |
| Persistence | shutdown during DNS/connect; admitted waiter/held-return, active return/abort, and idle prune/checkout races are covered |
| Cancellation races | abort and simultaneous cancellation/shutdown at every lease transition |
| Addressing | DNS fallback, IPv4/IPv6 literals, bracketed IPv6 Host, default and explicit ports, all-address failure |
| TLS | trust-chain rejection distinct from hostname mismatch and shutdown during provider setup |
| Resource behavior | descriptor counts after every remaining failure class and abort at each lease transition |

Each deterministic case should assert both the caller-visible outcome and the
pool/descriptor lifecycle. Timing checks use bounded deadlines only; they do
not assert scheduler traces or exact wall-clock coincidences.

## External scenario sources

The checked-in response corpus derives its expected outcomes from the current
HTTP specifications, principally [RFC 9112](https://www.rfc-editor.org/rfc/rfc9112.html)
Sections 2.2-2.3, 4, 5.1-5.2, 6.1-6.3, and 7.1-7.1.2, plus
[RFC 9110](https://www.rfc-editor.org/rfc/rfc9110.html) Sections 5.5, 6.5.1,
8.6, and 15. Each seed has a stable descriptive name, expected disposition,
and section reference in `http_client_rfc_seeds.adb`. The corpus is executable:
`http_client_rfc_corpus.adb` checks every unmodified seed, while
`http_client_parser_randomized.adb` uses the same seeds as mutation bases.
That arrangement keeps the standards examples reviewable in source control
without treating a generated fuzzing artifact as the requirement ledger.

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
the process descriptor baseline. `http_client_pool_races.adb` uses test-only
connection barriers to force active return and abort against shutdown, holds a
lease while an admitted waiter is interrupted, races idle pruning against
checkout, and checks both the drained counter state and process descriptor
baseline. `http_client_deadline_matrix.adb` uses the same compiled-out hooks to
hold every DNS-through-body phase until its deadline expires or an active
cancellation is requested, in both task lanes. Internal-only slot phases remain
deliberately outside the public API. `http_client_fragmentation.adb` caps every
connection receive at one byte and asserts the exact response-wire-length call
count, so TCP write coalescing cannot weaken its delimiter-boundary claim.

`Flyology.HTTP.Client.Testing.Fuzz_Response` is a stateless wrapper around the
production status, header, length, chunk, and trailer validators. It accepts a
fixed 1,000-byte array plus a prefix length. Documented protocol and size
rejections are normal outcomes; assertion failures, runtime checks, hangs, and
other exceptions remain crashes. The RFC corpus and fixed-seed mutation test
call that same wrapper. The larger exact-boundary cases stay in the deterministic
parser matrix because GNATfuzz's automatic marshaller limits array parameters
to 1,000 components.

Run `./scripts/http-client-fuzz.sh prepare` through Alire when the AdaCore tool
is available. It analyzes the dedicated wrapper, selects its reported
subprogram id, generates an isolated `afl_plain` harness, builds it, and creates
a starting corpus under ignored `build/gnatfuzz/http-client`. Run
`./scripts/http-client-fuzz.sh fuzz` for the campaign. Replay every saved crash
and record the tool version, seed revision, duration, engines, coverage
plateau, and minimized reproducer. GNATfuzz was not available in the current
toolchain, so no fuzz result or generated binary corpus is claimed here. The
human-readable RFC seeds remain checked in independently of that generated
TGen corpus.
