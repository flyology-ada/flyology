# Proof Status: Fable 5 prevention coverage
<!-- Reflect the top-level goal given. Items in the list below are moved from
     Not Started to In Progress to Reviewed and finally to Proved and Finalized. -->

The existing proof suite is green at level 1. This campaign is assessing which
confirmed Fable 5 defects can be prevented by proof of production policy rather
than by OS integration, concurrency stress, ABI checks, or evidence-pipeline
tests.

## Proved and Finalized
<!-- Before marking an item complete here, follow the Widen Scope step
     (Strategic Loop Step 5) in workflow.md in the /gnatprove Skill.
     Remember: changes to types used by or called subprograms in a given
     subprogram may cause it to regress to an unproved state. Reproving at the
     wider scope is thus a critical means to detect these situations. -->

- [x] Existing application policy suite (level 1, mode all; 192 checks)
- [x] Existing runtime scheduling policy suite (level 1, mode all; 47 checks)

## Reviewed
<!-- Before marking an item complete here, review it following the Review
     step (Strategic Loop Step 4) in workflow.md in the /gnatprove Skill -->

- [ ] Fable 5 prevention-coverage additions

## In Progress
<!-- A subagent executes the Tactical Loop for the subprogram below.
     It should update this section as it works. -->

- [ ] Classify confirmed findings by realistic SPARK preventability

## Not Started
<!-- Whenever a subprogram is added (due to refactoring) or discovered
     during assessment (Strategic Loop Steps 1-2), list it here so it
     is not forgotten. -->

- [ ] Numeric overflow and range-policy candidates
- [ ] Protocol parser and state-transition candidates
- [ ] Runtime ownership and scheduling-policy candidates

## Discovered Obligations

- [ ] Re-run the application and runtime proof suites serially after integration
- [ ] Confirm every added policy is used by production code or explicitly proves
      a production contract; do not accept disconnected duplicate models
