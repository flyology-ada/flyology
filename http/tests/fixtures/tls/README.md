# TLS test fixture

`../../scripts/prepare-test-tls.sh` generates `server-cert.pem` and
`server-key.pem` as a short-lived self-signed pair for `localhost`. The files
are ignored and remain local to the checkout. They must never be used outside
the test suite.

`mismatched_crypto.c` is compiled during the smoke run and placed beside a
real `libssl`. It exports only a version probe and verifies that the adapter
rejects a `libssl`/`libcrypto` pair that is not one loader dependency set.
