# Review cycle

- Complete a review cycle for every architectural decision and implementation
  change before presenting it as complete or ready to merge. Review a proposed
  architecture before implementation when practical, then review the resulting
  change for fidelity to that decision.
- Perform an explicit findings sweep against the request, established
  contracts and invariants, correctness, safety, compatibility, and relevant
  tests and documentation. Tests and proof runs provide evidence but do not
  replace the findings sweep.
- Prefer a reviewer with independent context when one is available. Otherwise
  perform a separate, deliberate self-review pass rather than treating ongoing
  implementation inspection as the review.
- Assign each finding a priority using the repository's established severity
  convention. If none exists, state the rubric used so P0, P1, and P2 have a
  reviewable meaning.
- Fix every P0 and P1 finding before completion. Treat P2 findings as
  fix-by-default; defer one only when the fix would materially expand scope or
  requires an unresolved user decision, and disclose the finding, impact, and
  proposed disposition and obtain explicit authorization to defer it. If a P0
  or P1 cannot be fixed within the authorized scope, report the blocker rather
  than claiming completion.
- After fixes, repeat the relevant review and verification until no P0 or P1
  finding remains and every P2 is either fixed or its deferral has been
  explicitly authorized. Do not close a finding by silently lowering its
  priority.
- Report the final findings state and the evidence used to verify fixes. Say
  explicitly when the sweep found no actionable findings.
