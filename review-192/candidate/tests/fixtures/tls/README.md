# TLS test fixture

`server-cert.pem` is a self-signed certificate for `localhost` and
`server-key.pem` is its private key. They exist only for deterministic local
tests. The key is public, is not a secret, and must never be used outside the
test suite.

`mismatched_crypto.c` is compiled during the smoke run and placed beside a
real `libssl`. It exports only a version probe and verifies that the adapter
rejects a `libssl`/`libcrypto` pair that is not one loader dependency set.
