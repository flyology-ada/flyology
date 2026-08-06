# Flyology HTTP

Flyology HTTP is an experimental HTTP/1.1 client and server library for
[Flyology](https://flyology.org/) tasks. Its synchronous Ada APIs work from
native and lightweight tasks. The library includes bounded client pools,
streaming request and response bodies, routing, middleware, server-sent events,
WebSockets, and plain or TLS transports built on Flyology I/O.

The project is being prepared for publication at
[http.flyology.org](https://http.flyology.org/) and in the
[`flyology-ada/flyology-http`](https://github.com/flyology-ada/flyology-http)
repository.

## Build in this repository

```sh
cd http
alr build
./scripts/test.sh
```

The local manifest pins `flyology` to the parent directory. The test runner
prepares a version-matched Flyology runtime, builds the HTTP library as a
separate GPR library, and runs its client, server, WebSocket, TLS, policy, and
negative lifetime tests.

## Use with Alire

Until the crates have community-index releases, add the Flyology organization
index ahead of the community index and depend on both crates:

```sh
alr index --reset-community
alr index --add=git+https://github.com/flyology-ada/alire-index.git \
  --name=flyology --before=community
alr with flyology_http
```

The `flyology_http` dependency brings in Flyology. Applications still configure
and prepare Flyology's version-matched runtime as described in the
[Flyology guide](https://flyology.org/guide/).

## Scope

- HTTP/1.0 response compatibility and HTTP/1.1 client and server messages.
- Origin-bound client pools with one monotonic exchange deadline.
- Fixed-length and chunked bodies with bounded streaming adapters.
- Optional routing, middleware, native offload, SSE, and WebSocket facilities.
- Provider-neutral TLS integration through Flyology I/O.

The library does not currently provide HTTP/2, proxying, or content decoding.
It is experimental and does not claim production qualification.

Flyology HTTP is dual-licensed under MIT or Apache-2.0.
