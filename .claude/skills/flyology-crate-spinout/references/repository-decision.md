# Decide the crate and repository boundary

Inspect the implementation and its real consumers before recommending a
boundary. Trace dependencies in both directions, shared types and invariants,
build and verification coupling, platform assumptions, generated sources,
release cadence, and ownership of public behavior.

## Decision criteria

Evaluate all three placements:

| Placement | Prefer when | Main cost or warning |
| --- | --- | --- |
| Package in the current crate | The code shares invariants, internal types, atomic changes, or one release lifecycle with its parent. | The boundary is organizational rather than independently consumable. |
| Independent crate in the current repository | The API and dependency direction are coherent, but changes, tests, proofs, or releases still need repository-level coordination. | Build independence can be mistaken for lifecycle independence. |
| Independent repository | The crate is independently useful, has a stable dependency boundary, needs an independent release/support lifecycle, or has distinct ownership and credible consumers. | Atomic changes become coordinated releases and consumers can experience version skew. |

A new repository is stronger when several of these are evidenced:

- the public API is coherent without exposing parent internals;
- dependencies point in one sustainable direction and do not form a cycle;
- more than one actual or near-term consumer needs the component;
- releases, compatibility, platform support, or verification can be managed
  independently;
- ownership or contribution boundaries are meaningfully distinct;
- licensing and retained history can be carried across cleanly.

Evidence against a new repository includes frequent atomic cross-boundary
changes, private representation leakage, a dependency cycle, coupled proof or
runtime invariants, a single inseparable consumer, or no independent release
story. Do not use line count, directory size, build duration, naming
preference, or hypothetical reuse as decisive evidence.

## Required output

Present a decision record with:

1. the capability and proposed public boundary;
2. known consumers and dependency direction;
3. a comparison of the three placements;
4. the recommendation and evidence;
5. compatibility, versioning, release, CI, documentation, and ownership costs;
6. open decisions that require user authority;
7. a reversible validation step, when uncertainty can be reduced by first
   creating an internal crate boundary.

If evidence is incomplete, recommend the least irreversible next step. An
in-repository crate can test the API and dependency boundary before creating a
remote or splitting history.
