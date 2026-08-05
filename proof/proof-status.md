# Proof Status: Fable 5 prevention coverage
<!-- Reflect the top-level goal given. Items in the list below are moved from
     Not Started to In Progress to Reviewed and finally to Proved and Finalized. -->

Finding #5 is addressed by a nonzero `Unsigned_64` generation-successor policy
called directly by production `Flyology.Native_Executors`. Both the targeted
subprogram proof and fresh whole-unit widening are green at level 1.

## Proved and Finalized
<!-- Before marking an item complete here, follow the Widen Scope step
     (Strategic Loop Step 5) in workflow.md in the /gnatprove Skill.
     Remember: changes to types used by or called subprograms in a given
     subprogram may cause it to regress to an unproved state. Reproving at the
     wider scope is thus a critical means to detect these situations. -->

- [x] Pre-change application policy suite (level 1, mode all)
- [x] Pre-change runtime scheduling policy suite (level 1, mode all)
- [x] Finding #5 production-used nonzero generation-successor policy
      (level 1, mode all)
  - [x] `Flyology.Counter_Policy.Nonzero_Successor`
  - [x] Whole `Flyology.Counter_Policy` unit widening

## Reviewed
<!-- Before marking an item complete here, review it following the Review
     step (Strategic Loop Step 4) in workflow.md in the /gnatprove Skill -->

- None.

## In Progress
<!-- A subagent executes the Tactical Loop for the subprogram below.
     It should update this section as it works. -->

- None.

## Not Started
<!-- Whenever a subprogram is added (due to refactoring) or discovered
     during assessment (Strategic Loop Steps 1-2), list it here so it
     is not forgotten. -->

- None.

## Discovered Obligations

- [x] Production `Native_Executors.Submit` consumes `Nonzero_Successor`
- [x] Boundary tests cover zero, the last ordinary increment, and rollover
- [x] Run the targeted subprogram proof through a tactical subagent
- [x] Review the proved policy for SPARK contract and refactoring antipatterns
- [x] Re-run the whole `Flyology.Counter_Policy` unit after targeted proof
