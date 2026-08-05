# Proof Status: Fable 5 prevention coverage
<!-- Reflect the top-level goal given. Items in the list below are moved from
     Not Started to In Progress to Reviewed and finally to Proved and Finalized. -->

Findings #5, #12, #13, #14, #15, #16, #17, #18, and #19 are prevented by
production-consumed SPARK units. Their assigned targeted subprogram proofs and
fresh whole-unit widenings passed at level 1.
The chunk encoder proof includes complete hexadecimal-digit consumption through
`Natural'Last`, so the historical seven-digit capacity cannot prove.
Finding #13 proves the negotiated encoder-window bound. Finding #18 proves only
exact distance-tree classification and missing-distance enforcement; it
excludes reserved-symbol rejection and does not claim general DEFLATE
correctness.
The WebSocket timeout classifier treats failed-or-terminal state as an input
and does not prove that the I/O core sets that state, so behavioral integration
coverage remains required.
Finding #12 uses the production connection's persistent frame cursor. Its
proved transitions preserve payload phase, frame identity, remaining bytes,
absolute mask position, and the separate completion and abandonment reset
boundaries. Focused behavioral coverage exercises the surrounding I/O paths;
protocol I/O itself remains outside SPARK.
Finding #1 has partial prevention coverage. Its targeted proofs and fresh
whole-unit widening passed at level 1 and mode all, establishing only bounded
batch budgets and the deterministic Ada file-drain latch and state transitions
consumed by Linux `Wait_Batch`. They do not prove kernel readiness or liveness,
eventfd, epoll, io_uring, the C bridge, CQE existence or delivery, or buffer
ownership; Linux integration and stress coverage remain authoritative for
those behaviors. The widening continued with partial representation data after
the non-code-generating root package spec `s-flyolo.ads` produced no
representation information; the poller-policy unit itself was analyzed with no
warning, assumption, justified check, or unproved check.

## Proved and Finalized
<!-- Before marking an item complete here, follow the Widen Scope step
     (Strategic Loop Step 5) in workflow.md in the /gnatprove Skill.
     Remember: changes to types used by or called subprograms in a given
     subprogram may cause it to regress to an unproved state. Reproving at the
     wider scope is thus a critical means to detect these situations. -->

- [x] Pre-change application policy suite (level 1, mode all)
- [x] Pre-change runtime scheduling policy suite (level 1, mode all)
- [x] Finding #1 production-used deterministic poller batch policy
      (level 1, mode all; partial prevention boundary)
  - [x] `System.Flyology.Poller_Policy.Plan_Batch`
  - [x] `System.Flyology.Poller_Policy.Remaining_Budget`
  - [x] `System.Flyology.Poller_Policy.After_Wake`
  - [x] `System.Flyology.Poller_Policy.After_Drain`
  - [x] `System.Flyology.Poller_Policy.After_Batch`
  - [x] Whole `System.Flyology.Poller_Policy` unit widening
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
- [x] Finding #12 production-used incremental WebSocket frame cursor
      (level 1, mode all)
  - [x] `Flyology.WebSocket_Policy.Begin_Frame`
  - [x] `Flyology.WebSocket_Policy.Mask_Offset`
  - [x] `Flyology.WebSocket_Policy.Advance`
  - [x] `Flyology.WebSocket_Policy.Complete_Frame`
  - [x] `Flyology.WebSocket_Policy.Abandon_Frame`
  - [x] Whole `Flyology.WebSocket_Policy` unit widening
- [x] Finding #19 production-used WebSocket timeout retry policy
      (level 1, mode all)
  - [x] `Flyology.WebSocket_Policy.Classify_Timeout`
  - [x] Whole `Flyology.WebSocket_Policy` unit widening
- [x] Finding #15 production-used HTTP Expect/version classification
      (level 1, mode all)
  - [x] `Flyology.HTTP.Expect_Policy.Classify`
  - [x] Whole `Flyology.HTTP.Expect_Policy` unit widening
- [x] Finding #17 production-used route-parameter capacity transition
      (level 1, mode all)
  - [x] `Flyology.HTTP.Route_Parameter_Policy.Advance`
  - [x] Whole `Flyology.HTTP.Route_Parameter_Policy` unit widening
- [x] Finding #13 production-used negotiated encoder-window bound
      (level 1, mode all)
  - [x] `Flyology.WebSocket_Deflate_Policy.Negotiated_Server_Window_Bits`
  - [x] Whole `Flyology.WebSocket_Deflate_Policy` unit widening
- [x] Finding #18 production-used distance-tree classification and
      missing-distance enforcement (level 1, mode all)
  - [x] `Flyology.WebSocket_Deflate_Policy.Select_Distance_Tree`
  - [x] `Flyology.WebSocket_Deflate_Policy.Distance_Requirement_Is_Satisfied`
  - [x] Whole `Flyology.WebSocket_Deflate_Policy` unit widening

## Reviewed
<!-- Before marking an item complete here, review it following the Review
     step (Strategic Loop Step 4) in workflow.md in the /gnatprove Skill -->

- [x] Finding #5 prevention coverage
- [x] Finding #14 prevention coverage
- [x] Finding #16 prevention coverage
- [x] Finding #12 prevention coverage
- [x] Finding #19 prevention coverage
- [x] Finding #15 prevention coverage
- [x] Finding #17 prevention coverage
- [x] Finding #13 prevention coverage
- [x] Finding #18 missing-distance prevention coverage
- [x] Finding #1 deterministic poller-policy boundary

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

- [x] Re-verified callers of `Begin_Frame`, `Mask_Offset`, `Advance`,
      `Complete_Frame`, and `Abandon_Frame` contracts
- [x] Fresh host `-f` widening for `Begin_Frame`
- [x] Fresh host `-f` widening for `Mask_Offset`
- [x] Fresh host `-f` widening for `Advance`
- [x] Fresh host `-f` widening for `Complete_Frame`
- [x] Fresh host `-f` widening for `Abandon_Frame`
- [x] Production `Begin_Frame` caller supplies the unconstrained
      cursor required for its discriminant-changing transition
- [x] Production `Complete_Frame` caller supplies the
      unconstrained cursor required for its discriminant-changing transition
- [x] Production `Abandon_Frame` callers supply the unconstrained cursor
      required for its discriminant-changing transition
- [x] Widened the revised `Flyology.WebSocket_Policy` unit at level 1 and mode
      all after the tactical subprogram proofs
- [x] Production `Receive_WebSocket` consumes the cursor state and
      transitions, including phase-gated header parsing
- [x] Deterministically cover repeated mid-header and masked mid-payload
      quantum timeouts with fragmented data and an interleaved control frame
- [x] Re-ran the focused production build and WebSocket smoke tests after the
      final cursor contracts
- [ ] Re-run the application and runtime proof suites serially after integration
- [x] Prove finding #1 `Poller_Policy.Plan_Batch` at targeted subprogram scope
- [x] Prove finding #1 `Poller_Policy.After_Wake` at targeted subprogram scope
- [x] Prove finding #1 `Poller_Policy.Remaining_Budget` at targeted subprogram
      scope
- [x] Prove finding #1 `Poller_Policy.After_Batch` at targeted subprogram scope
- [x] Cover finding #1 `Poller_Policy.After_Drain` in the whole-unit widening
- [x] Widen finding #1 through the whole `Poller_Policy` unit
- [x] Linux `Wait_Batch` consumes the bounded batch budgets and persistent
      file-drain state transitions
- [x] Boundary tests cover a consumed wake with a full 64-event epoll batch,
      conservative drain retention, and one-result source alternation
- [x] Prove `Flyology.HTTP.Expect_Policy.Classify`, then widen its whole unit
- [x] Prove `Flyology.HTTP.Route_Parameter_Policy.Advance`, then widen its
      whole unit
- [x] Production HTTP parser consumes the `Expect_Policy.Classify` action
- [x] Production `Validate_Pattern` consumes `Route_Parameter_Policy.Advance`
- [x] Boundary tests cover the Expect truth table and route capacity transition
- [x] Production `Native_Executors.Submit` consumes `Nonzero_Successor`
- [x] Production rate-limit middleware consumes `Refilled_Tokens`
- [x] Production HTTP chunk and SSE paths consume `HTTP_Chunk_Encoding.Encode`
- [x] Production high-level WebSocket handler consumes
      `WebSocket_Policy.Classify_Timeout`
- [x] Boundary tests cover generation rollover, refill saturation, and chunk
      encoding through `Natural'Last`
- [x] Behavioral tests cover failed exchange state and propagation for terminal
      control-write and message-deadline timeouts, plus active receive-quantum
      retry
- [x] Prove finding #13 window capability at targeted subprogram scope
- [x] Prove finding #18 distance-tree selection at targeted subprogram scope
- [x] Prove finding #18 missing-distance enforcement at targeted subprogram
      scope
- [x] Review finding #18 policy revision for proof antipatterns
- [x] Widen the revised WebSocket DEFLATE policy unit at level 1 and mode all
- [x] Production negotiation and the fixed-window encoder consume one shared
      WebSocket DEFLATE capability policy
- [x] Production dynamic-block tree construction and symbol decoding consume
      the empty-distance-tree classification and missing-distance policy;
      reserved-symbol rejection remains separate
- [x] Focused policy tests cover supported and unsupported window offers, the
      exact one-zero-code `No_Tree` shape, missing-distance enforcement, and
      the separate 286/287 reserved-symbol boundary
