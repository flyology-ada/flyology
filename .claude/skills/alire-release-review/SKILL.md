---
name: alire-release-review
description: Review an Ada crate for an Alire and Git release. Use for version changes, dependency constraints, manifests, immutable tags, release checks, or publication readiness. Do not publish or tag without explicit authorization.
license: Apache-2.0
metadata:
  version: "0.1.0"
---

# Review an Alire release

Read the repository's release instructions, `alire.toml`, maintained release
scripts, recent tags, and default branch. Establish the intended crate name,
version, tag namespace, supported toolchain, and publication target from the
repository and user direction.

Check:

- manifest name and version consistency;
- development versus stable dependency constraints;
- path and Git pins that cannot be published as intended;
- build profiles, platform availability, licenses, maintainers, and source
  archive contents;
- generated files and nested test crates;
- changelog or release-note evidence;
- clean builds, tests, proofs, documentation, and repository-specific checks;
- whether the proposed tag already exists locally or remotely.

Separate readiness review from publication. Do not create, move, delete, or
push a tag and do not submit an index change unless the user explicitly
authorizes that action and exact version.

Report blocking findings, warnings, commands and revisions checked, the exact
proposed immutable tag, and the remaining authorized publication steps.
