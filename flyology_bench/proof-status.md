# Proof Status: Flyology_Bench baseline numeric policy
<!-- Reflect the top-level goal given. Items in the list below are moved from
     Not Started to In Progress to Reviewed and finally to Proved and Finalized. -->

Ubuntu CI showed that level-1 proof of the floating-point bounds in `Ratio`
and `Time_Change` can exhaust the default one-second prover time limit.  Their
nonlinear obligations are split into smaller proof steps, and the isolated
benchmark proof receives a two-second timeout.  The contracts, returned values,
and global proof level are unchanged.
`Flyology_Bench.Baselines` remains outside SPARK because it owns file I/O,
exceptions, bootstrap orchestration, and controlled measurements; behavioral
tests cover that integration and its explicit range guards.

## Proved and Finalized
<!-- Before marking an item complete here, follow the Widen Scope step
     (Strategic Loop Step 5) in workflow.md in the /gnatprove Skill.
     Remember: changes to types used by or called subprograms in a given
     subprogram may cause it to regress to an unproved state. Reproving at the
     wider scope is thus a critical means to detect these situations. -->

- [x] `Flyology_Bench.Baseline_Math` (level 1, mode all, 2-second timeout)

## Reviewed
<!-- Before marking an item complete here, review it following the Review
     step (Strategic Loop Step 4) in workflow.md in the /gnatprove Skill -->

## In Progress
<!-- A subagent executes the Tactical Loop for the subprogram below.
     It should update this section as it works. -->

## Not Started
<!-- Whenever a subprogram is added (due to refactoring) or discovered
     during assessment (Strategic Loop Steps 1-2), list it here so it is not
     forgotten. -->

## Discovered Obligations
- [x] `Flyology_Bench.Baseline_Math` (level 1, mode all)
  - [x] `Add_To_Sum` bounded result contract and run-time checks
  - [x] `Mean` bounded result contract and run-time checks
  - [x] `Ratio` bounded result contract and run-time checks
  - [x] `Time_Change` bounded result contract and run-time checks
  - [x] `Interpolate` bounded floating-point run-time checks
  - [x] `Classify` complete, disjoint interval-verdict contract cases
