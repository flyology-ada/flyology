# Proof Status: Relocatable data-structure policy
<!-- Reflect the top-level goal given. Items in the list below are moved from
     Not Started to In Progress to Reviewed and finally to Proved and Finalized. -->

The production data-structure packages consume proved scalar policy for shared
layout arithmetic, modular ring decisions, bounded probe/slot selection, and
non-wrapping generation policy while retaining native addresses, atomics, and
byte copying as explicit trusted boundaries.

## Proved and Finalized
<!-- Before marking an item complete here, follow the Widen Scope step
     (Strategic Loop Step 5) in workflow.md in the /gnatprove Skill.
     Remember: changes to types used by or called subprograms in a given
     subprogram may cause it to regress to an unproved state. Reproving at the
     wider scope is thus a critical means to detect these situations. -->

- [x] Flyology public-library proof suite (level 1, mode all)
  - [x] Flyology.Data_Structures.Policy (level 1, mode all)
    - [x] `Valid_Lifecycle`, `State_Epoch`, and `State_Lifecycle`
    - [x] `Make_State`, `Valid_State`, `Epoch_Can_Advance`, and `Next_Epoch`
    - [x] `Addition_Fits`, `Add`, and `Multiplication_Fits`
    - [x] `Is_Power_Of_Two`, `Alignment_Fits`, and `Slice_Fits`
    - [x] `Within_Capacity`, `Classify_Sequence`, and `Masked_Index`
    - [x] `Allocation_Slot`, `Generation_Can_Advance`, and `Next_Generation`
    - [x] `Buddy_Node_Count_Fits`, `Buddy_Node_Count`, `Buddy_Parent`, and
          `Buddy_Sibling`

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

- [x] Make every proved policy function production-consumed
- [x] Re-verify every data-structure consumer after policy extraction
- [x] Retain native address conversion, atomics, and raw byte copying outside
      SPARK and cover those boundaries behaviorally
- [x] Add boundary tests for generation exhaustion and every corrected finding
