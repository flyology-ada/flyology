-------------------- MODULE SupervisionRestartWindow --------------------
EXTENDS Naturals

(***************************************************************************
Bounded restart-window extraction shared by SupervisionLifecycle and its Ada
conformance replay.  The fixture begins with one static generation and one
family generation running, then makes the current generation stable.  Each
admitted restart increments the static child, static subtree, and family slot
accounts once.  Static subtree readiness is invalidated in the failure
transition that enters recovery; child and family-slot readiness are
invalidated when a replacement starts.

The state and harness type ranges are parameterized by MaxAttempts so the
parent model remains configurable.
***************************************************************************)

CONSTANTS MaxAttempts, LifecyclePolicy

VARIABLES phase, now,
          staticReadySince, subtreeReadySince, familyReadySince,
          staticUsed, subtreeUsed, familyUsed,
          staticStarts, familyStarts, exhausted, lastAction

restartVars ==
  <<phase, now,
    staticReadySince, subtreeReadySince, familyReadySince,
    staticUsed, subtreeUsed, familyUsed,
    staticStarts, familyStarts, exhausted, lastAction>>

NoReadiness == 2
StabilityReset == 1

RestartWindowInit ==
  /\ phase = "starting"
  /\ now = 0
  /\ staticReadySince = NoReadiness
  /\ subtreeReadySince = NoReadiness
  /\ familyReadySince = NoReadiness
  /\ staticUsed = 0
  /\ subtreeUsed = 0
  /\ familyUsed = 0
  /\ staticStarts = 1
  /\ familyStarts = 1
  /\ exhausted = FALSE
  /\ lastAction = "Init"

RestartTimestampIsStable(timestamp) ==
  /\ timestamp # NoReadiness
  /\ now >= timestamp
  /\ now - timestamp >= StabilityReset

RestartCountAfterFailure(timestamp, used) ==
  IF RestartTimestampIsStable(timestamp) THEN 1 ELSE used + 1

RestartCanBeAdmitted ==
  /\ (IF RestartTimestampIsStable(staticReadySince) THEN 0 ELSE staticUsed) < MaxAttempts
  /\ (IF RestartTimestampIsStable(subtreeReadySince) THEN 0 ELSE subtreeUsed) < MaxAttempts
  /\ (IF RestartTimestampIsStable(familyReadySince) THEN 0 ELSE familyUsed) < MaxAttempts

MarkRestartReady ==
  /\ phase = "starting"
  /\ phase' = "ready-await-stability"
  /\ staticReadySince' = now
  /\ subtreeReadySince' = now
  /\ familyReadySince' = now
  /\ lastAction' = "MarkRestartReady"
  /\ UNCHANGED <<now, staticUsed, subtreeUsed, familyUsed,
                  staticStarts, familyStarts, exhausted>>

AdvanceRestartTime ==
  /\ phase = "ready-await-stability"
  /\ now < StabilityReset
  /\ phase' = "ready"
  /\ now' = StabilityReset
  /\ lastAction' = "AdvanceRestartTime"
  /\ UNCHANGED <<staticReadySince, subtreeReadySince, familyReadySince,
                  staticUsed, subtreeUsed, familyUsed,
                  staticStarts, familyStarts, exhausted>>

RestartFailure ==
  /\ phase \in {"ready", "starting-unready"}
  /\ IF RestartCanBeAdmitted
        THEN
          /\ phase' = "replacement-start"
          /\ staticUsed' = RestartCountAfterFailure(staticReadySince, staticUsed)
          /\ subtreeUsed' = RestartCountAfterFailure(subtreeReadySince, subtreeUsed)
          /\ familyUsed' = RestartCountAfterFailure(familyReadySince, familyUsed)
          /\ subtreeReadySince' =
               IF LifecyclePolicy = "restart-window-stale-broken"
               THEN subtreeReadySince
               ELSE NoReadiness
          /\ lastAction' = "RestartFailure"
          /\ UNCHANGED <<now, staticReadySince, familyReadySince,
                          staticStarts, familyStarts, exhausted>>
        ELSE
          /\ phase' = "exhausted"
          /\ exhausted' = TRUE
          /\ lastAction' = "RestartExhausted"
          /\ UNCHANGED <<now,
                          staticReadySince, subtreeReadySince, familyReadySince,
                          staticUsed, subtreeUsed, familyUsed,
                          staticStarts, familyStarts>>

StartRestartGeneration ==
  /\ phase = "replacement-start"
  /\ staticStarts < MaxAttempts + 2
  /\ familyStarts < MaxAttempts + 2
  /\ phase' = "starting-unready"
  /\ staticReadySince' =
       IF LifecyclePolicy = "restart-window-stale-broken"
       THEN staticReadySince
       ELSE NoReadiness
  /\ familyReadySince' =
       IF LifecyclePolicy = "restart-window-stale-broken"
       THEN familyReadySince
       ELSE NoReadiness
  /\ staticStarts' = staticStarts + 1
  /\ familyStarts' = familyStarts + 1
  /\ lastAction' = "StartRestartGeneration"
  /\ UNCHANGED <<now, subtreeReadySince,
                  staticUsed, subtreeUsed, familyUsed, exhausted>>

RestartWindowNext ==
  MarkRestartReady
    \/ AdvanceRestartTime
    \/ RestartFailure
    \/ StartRestartGeneration

RestartWindowSpec ==
  RestartWindowInit /\ [][RestartWindowNext]_restartVars

RestartWindowTypeOK ==
  /\ phase \in
       {"starting", "ready-await-stability", "ready", "replacement-start",
        "starting-unready", "exhausted"}
  /\ now \in 0 .. 1
  /\ staticReadySince \in 0 .. 2
  /\ subtreeReadySince \in 0 .. 2
  /\ familyReadySince \in 0 .. 2
  /\ staticUsed \in 0 .. MaxAttempts
  /\ subtreeUsed \in 0 .. MaxAttempts
  /\ familyUsed \in 0 .. MaxAttempts
  /\ staticStarts \in 1 .. (MaxAttempts + 2)
  /\ familyStarts \in 1 .. (MaxAttempts + 2)
  /\ exhausted \in BOOLEAN
  /\ lastAction \in
       {"Init", "MarkRestartReady", "AdvanceRestartTime", "RestartFailure",
        "StartRestartGeneration", "RestartExhausted"}

(***************************************************************************
The checked conformance fixture fixes MaxAttempts = 3.  flyology-tla requires
literal integer bounds in its type operators, so this invariant and
HarnessOutcomeType must stay in sync with
SupervisionLifecycle_restart_window_trace.cfg.
***************************************************************************)

RestartWindowHarnessTypeOK ==
  /\ phase \in
       {"starting", "ready-await-stability", "ready", "replacement-start",
        "starting-unready", "exhausted"}
  /\ now \in 0 .. 1
  /\ staticReadySince \in 0 .. 2
  /\ subtreeReadySince \in 0 .. 2
  /\ familyReadySince \in 0 .. 2
  /\ staticUsed \in 0 .. 3
  /\ subtreeUsed \in 0 .. 3
  /\ familyUsed \in 0 .. 3
  /\ staticStarts \in 1 .. 5
  /\ familyStarts \in 1 .. 5
  /\ exhausted \in BOOLEAN
  /\ lastAction \in
       {"Init", "MarkRestartReady", "AdvanceRestartTime", "RestartFailure",
        "StartRestartGeneration", "RestartExhausted"}

RestartReadinessBelongsToCurrentGeneration ==
  /\ (phase = "starting-unready" =>
        /\ staticReadySince = NoReadiness
        /\ familyReadySince = NoReadiness)
  /\ (phase \in {"replacement-start", "starting-unready"} =>
        subtreeReadySince = NoReadiness)

RestartAttemptsStayBounded ==
  /\ staticStarts <= MaxAttempts + 1
  /\ familyStarts <= MaxAttempts + 1

RestartWindowWitnessPending == phase # "exhausted"

HarnessInputType ==
  [step :
     {"Init", "MarkRestartReady", "AdvanceRestartTime", "RestartFailure",
      "StartRestartGeneration", "RestartExhausted"}]

HarnessOutcomeType ==
  [staticStarts : 1 .. 5,
   familyStarts : 1 .. 5,
   staticUsed : 0 .. 3,
   subtreeUsed : 0 .. 3,
   familyUsed : 0 .. 3,
   exhausted : BOOLEAN]

RestartRole ==
  CASE lastAction = "MarkRestartReady" -> "mark-ready"
    [] lastAction = "AdvanceRestartTime" -> "advance-time"
    [] lastAction = "RestartFailure" -> "fail"
    [] lastAction = "RestartExhausted" -> "fail"
    [] lastAction = "StartRestartGeneration" -> "start-generation"
    [] OTHER -> "init"

Alias ==
  [action |-> lastAction,
   role |-> RestartRole,
   input |-> [step |-> lastAction],
   outcome |->
     [staticStarts |-> staticStarts,
      familyStarts |-> familyStarts,
      staticUsed |-> staticUsed,
      subtreeUsed |-> subtreeUsed,
      familyUsed |-> familyUsed,
      exhausted |-> exhausted],
   state |->
     [phase |-> phase,
      now |-> now,
      staticReadySince |-> staticReadySince,
      subtreeReadySince |-> subtreeReadySince,
      familyReadySince |-> familyReadySince,
      staticStarts |-> staticStarts,
      familyStarts |-> familyStarts,
      staticUsed |-> staticUsed,
      subtreeUsed |-> subtreeUsed,
      familyUsed |-> familyUsed,
      exhausted |-> exhausted,
      lastAction |-> lastAction],
   model_source |-> lastAction]

=============================================================================
