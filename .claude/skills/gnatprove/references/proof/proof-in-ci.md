# Running GNATprove in CI: proof caching, gate design, provisioning

Proof in CI can be time-consuming. This file provides strategies for increasing
efficiency.

## Proof caching using memcached with the `file:` backend

GNATprove caches *prover verdicts*, keyed by verification condition.
Importantly, SPARK provides a `file:` backend that persists verdicts to a
**plain directory**. Once the cache is build, a warm run re-proves only the VCs
whose source actually changed in a given PR or commit.

The mechanism is:
* restore the directory before proving,
* point gnatprove at it,
* prove,
* save the directory back.

For example, in GitHub CI:

```yaml
- name: Restore proof cache
  uses: actions/cache/restore@v6
  with:
    path: .gnatprove-cache
    key: gnatprove-${{ runner.os }}-gp16.1.0-why3-1.8.2-${{ github.sha }}
    restore-keys: |
      gnatprove-${{ runner.os }}-gp16.1.0-why3-1.8.2-

- name: Prove
  env:
    GNATPROVE_EXTRA: >-
      --timeout=10
      --memcached-server=file:${{ github.workspace }}/.gnatprove-cache
  run: |
    mkdir -p .gnatprove-cache      # the only "server setup" there is
    make prove-check

- name: Save proof cache
  if: github.ref == 'refs/heads/main'   # trusted refs only — see below
  uses: actions/cache/save@v6
  with:
    path: .gnatprove-cache
    key: gnatprove-${{ runner.os }}-gp16.1.0-why3-1.8.2-${{ github.sha }}
```

**Pitfall**: don't stand up a real memcached service. The `file:` backend makes
this unnecessary and is the better fit for CI.

## Cache-gate design

Prefer to use a cache only if it was computed under the *same* prover
semantics. Three guidelines:

- **Fingerprint the key with the exact prover toolchain.** Include the gnatprove
  and why3 versions (and a SHA) in the cache key
  (`gnatprove-<os>-gp16.1.0-why3-1.8.2-<sha>`). A toolchain bump then lands on a
  fresh key, so upgraded provers can never reuse verdicts computed under
  different VC semantics.
- **Gate `save` on trusted refs only** (`github.ref == 'refs/heads/main'`, or a
  scheduled refresh job). Fork/PR runs `restore` and warm-start but must not
  `save`, or an untrusted run could poison the verdicts main trusts.
- **Run a periodic COLD reprove from an empty cache** as a guard (e.g. a
  daily `proof-cache-refresh.yml`). A from-scratch run re-runs every prover, so
  no corrupt cached verdict can survive it — nothing to inherit.

## Minimal proof-job provisioning

Gnatprove relies on loading GPR files and needs all build dependencies
available during the analysis, including ideally the target compiler. Some
setup may be required to ensure that dependencies are available.

## See also

- [gnatprove.md](../gnatprove/gnatprove.md) — CLI options, interpreting output
- [command-reference.md](../gnatprove/command-reference.md) — `--timeout`, `--steps`, `--level`
- [workflow.md](workflow.md) — full campaign structure
