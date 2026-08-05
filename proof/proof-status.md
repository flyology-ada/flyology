# Proof Status: Fable 5 prevention coverage
<!-- Reflect the top-level goal given. Items in the list below are moved from
     Not Started to In Progress to Reviewed and finally to Proved and Finalized. -->

Findings #5, #14, and #16 are prevented by production-consumed SPARK units.
Targeted subprogram proofs and fresh whole-unit widenings passed at level 1.
The chunk encoder proof includes complete hexadecimal-digit consumption through
`Natural'Last`, so the historical seven-digit capacity cannot prove.

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
- [x] Finding #14 production-used rate-limit refill policy
      (level 1, mode all)
  - [x] `Flyology.Rate_Limit_Policy.Refilled_Tokens`
  - [x] Whole `Flyology.Rate_Limit_Policy` unit widening
- [x] Finding #16 production HTTP chunk-size encoder
      (level 1, mode all)
  - [x] `Flyology.HTTP_Chunk_Encoding.Encode`
  - [x] Whole `Flyology.HTTP_Chunk_Encoding` unit widening

## Reviewed
<!-- Before marking an item complete here, review it following the Review
     step (Strategic Loop Step 4) in workflow.md in the /gnatprove Skill -->

- [x] Finding #5 prevention coverage
- [x] Finding #14 prevention coverage
- [x] Finding #16 prevention coverage

## In Progress
<!-- A subagent executes the Tactical Loop for the subprogram below.
     It should update this section as it works. -->

- None.

## Not Started
<!-- Whenever a subprogram is added (due to refactoring) or discovered
     during assessment (Strategic Loop Steps 1-2), list it here so it
     is not forgotten. -->

- [ ] Protocol parser and state-transition candidates
- [ ] Runtime ownership and scheduling-policy candidates

## Discovered Obligations

- [ ] Re-run the application and runtime proof suites serially after integration
- [x] Production `Native_Executors.Submit` consumes `Nonzero_Successor`
- [x] Production rate-limit middleware consumes `Refilled_Tokens`
- [x] Production HTTP chunk and SSE paths consume `HTTP_Chunk_Encoding.Encode`
- [x] Boundary tests cover generation rollover, refill saturation, and chunk
      encoding through `Natural'Last`
