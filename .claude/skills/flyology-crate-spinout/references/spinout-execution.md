# Execute an approved crate spinout

Confirm the approved target: crate name, repository owner and name, visibility,
license, initial version, compatibility intent, supported platforms and
toolchains, source-of-truth cutover, and whether history must be preserved.
Do not invent missing policy choices.

## Plan independently reviewable changes

Keep these concerns separable where practical:

1. establish or harden the boundary in the source repository;
2. extract or scaffold the target while preserving attribution and license;
3. reproduce applicable build, test, proof, documentation, release, and APM
   structure from the approved reference repository;
4. verify the target independently;
5. migrate each consumer to an explicit target revision;
6. remove the old source only after the new source and consumers are verified.

Avoid a single change that simultaneously redesigns the API, moves history,
changes behavior, and migrates every consumer. Preserve behavioral translation
separately from semantic repairs.

## Preserve provenance and contracts

- Choose a history-preserving extraction strategy when history matters, and
  obtain approval before filtering or rewriting history.
- Carry forward copyright, license, notices, contributor attribution, and
  generated-source provenance that apply to the extracted files.
- Inventory public API, defaults, representation, persisted formats, ABI,
  exceptions, ownership, concurrency, and platform behavior before moving it.
- Identify which compatibility promises survive the split and which require a
  versioned change or explicit migration.
- Break dependency cycles through an approved interface boundary; do not hide
  them with duplicate types, copied policy, or mutually pinned repositories.

## Reproduce the intended repository structure

Use the parity table from `SKILL.md` as the scaffold checklist. At minimum,
consider the reference repository's:

- `README.md`, license, contribution and release documentation;
- `alire.toml`, crate configuration, GPR projects, source directories, and
  formatting ownership;
- unit, integration, proof, ABI, platform, and generated-source checks;
- CI matrix, dependency caching, documentation publication, and release gates;
- repository-specific agent packages and shared APM dependencies.

Absence from the new repository must be intentional rather than an oversight.
Do not copy badges, support claims, secrets, branch protection assumptions, or
publishing configuration without verifying that they describe the new target.

## Provision APM

Model repo-specific agent resources as local APM packages and shared resources
as an updatable `flyology-ada/agents` dependency with an exact lock.

For an in-repository crate, preserve the repository's existing APM manifest and
locked shared revision unless the user authorizes a dependency change. Add a
local agent package only when the crate introduces genuinely repo-specific
guidance that is not already covered by the repository package. Verify the
existing graph with the frozen install, compilation, validation, and audit
commands below, omitting the initial unfrozen install.

A new repository has no lockfile yet, so create and verify its initial
resolution in this order:

```text
apm install
apm install --frozen
apm compile --target codex
apm compile --validate
apm audit --ci
```

After the lock exists, advance the shared dependency with
`apm update flyology-ada/agents --yes` only when the user has authorized that
dependency revision change, then repeat the frozen install, compilation,
validation, and audit sequence above without the initial unfrozen install. Use
`apm install --frozen` in CI and ordinary reproducible setup. Confirm that the
compiled `AGENTS.md`, native Claude rules, and both skill trees contain the
expected shared and local resources. Test with fresh client sessions rather
than relying only on file presence.

## Verify cutover

Build and test the source and target repositories independently. Then test each
consumer against the exact proposed target commit or release. Check clean-clone
setup, locked dependencies, generated-output drift, supported platforms, and
any proof, ABI, documentation, or release checks required by the chosen
reference repository.

Run a findings sweep after the architecture decision, after the target is
assembled, and after consumer migration. Report the exact revisions tested and
do not publish, merge, delete the old source, or retarget consumers until the
corresponding authorization and checks are complete.
