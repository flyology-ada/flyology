---- MODULE SupervisionLifecycle ----
EXTENDS FiniteSets, Naturals

(***************************************************************************
This is a bounded state-machine extraction of Flyology.Supervision.Static,
Flyology.Supervision.Families, and their shared Generation_Control protocol.

The fixed topology has one prerequisite and one dependent family owner.  The
owner runs a nested two-slot dynamic family and follows the documented
application readmission protocol before publishing outer readiness.  Recovery
impact remains nondeterministic, so the model explores isolate, cohort,
dependent-closure, and escalation decisions over that topology.

LifecyclePolicy selects the current implementation or one deliberately broken
boundary.  Broken variants admit a controller-stale command, construct a
replacement before the old generation joins, mint a new incident while
propagating nested escalation, publish an owner before desired-child
readmission, or omit nested parent-stop forwarding.  The checked
configurations require a concrete counterexample for each removed guarantee.

Time, exception payloads, event-ring storage, and retry-window arithmetic are
abstracted at their proved policy boundary.  MaxAttempts represents the
combined burst/total/deadline admission result: an admitted attempt increments
once, while exhaustion makes the node terminal without constructing another
generation.
***************************************************************************)

CONSTANTS Children, Prerequisite, Owner, FamilySlots,
          MaxGeneration, MaxAttempts, MaxController, LifecyclePolicy

OuterController == 1

ASSUME /\ Children = {Prerequisite, Owner}
       /\ Prerequisite # Owner
       /\ FamilySlots # {}
       /\ MaxGeneration \in Nat \ {0}
       /\ MaxAttempts \in Nat \ {0}
       /\ MaxController \in Nat \ {0}
       /\ MaxController >= OuterController
       /\ LifecyclePolicy \in
            {"current", "stale-authority-broken",
             "restart-before-join-broken", "no-parent-forwarding-broken",
             "nested-incident-mint-broken",
             "owner-ready-before-readmission-broken"}

NoChild == "no-child"
NoImpact == "no-impact"
Impacts == {"isolate", "cohort", "dependents", "escalate"}

OuterStates == {"configured", "starting", "ready", "running",
                 "stopping", "terminated", "joined"}
FamilyStates == {"free", "reserved", "queued", "starting", "running",
                  "stopping", "terminated", "backing-off", "reapable"}
Modes == {"unconfigured", "startup", "running", "recovery-stop",
           "recovery-backoff", "recovery-start", "shutdown-stop",
           "terminal-stop", "finished"}
Results == {"none", "shutdown-completed", "startup-failed",
             "recovery-exhausted", "failure-escalated", "child-stuck"}

Rank(c) == IF c = Prerequisite THEN 1 ELSE 2
Prerequisites(c) == IF c = Owner THEN {Prerequisite} ELSE {}
Cohort(c) == Children
DependentClosure(c) == IF c = Prerequisite THEN Children ELSE {Owner}

AffectedFor(c, impact) ==
  CASE impact = "isolate"    -> {c}
    [] impact = "cohort"     -> Cohort(c)
    [] impact = "dependents" -> DependentClosure(c)
    [] OTHER                  -> {}

NextAttempt(active, attempt) == IF active THEN attempt + 1 ELSE 1

VARIABLES mode, shutdown, terminal, result,
          childState, childLive, childReady, childStop, childStuck,
          generation, joinedGeneration,
          affected, trigger, recoveryImpact, incidentId, incidentAttempt,
          incidentActive, childIncident, childAttempt,
          lastStopRank, lastStartRank,
          familyOpen, familyController, retiredControllers,
          familyIncarnation, familyShutdown, familyTerminal,
          slotState, slotLive, slotReady, slotStop, slotRecover,
          slotGeneration, slotJoinedGeneration,
          nestedEscalation, nestedIncident, nestedAttempt,
          staleCommandAccepted, replacementBeforeJoin,
          ownerPublishedWithoutReplay, nestedIncidentMinted

vars == <<mode, shutdown, terminal, result,
          childState, childLive, childReady, childStop, childStuck,
          generation, joinedGeneration,
          affected, trigger, recoveryImpact, incidentId, incidentAttempt,
          incidentActive, childIncident, childAttempt,
          lastStopRank, lastStartRank,
          familyOpen, familyController, retiredControllers,
          familyIncarnation, familyShutdown, familyTerminal,
          slotState, slotLive, slotReady, slotStop, slotRecover,
          slotGeneration, slotJoinedGeneration,
          nestedEscalation, nestedIncident, nestedAttempt,
          staleCommandAccepted, replacementBeforeJoin,
          ownerPublishedWithoutReplay, nestedIncidentMinted>>

ExactOuterAuthority(c, controller, gen) ==
  /\ c \in Children
  /\ controller = OuterController
  /\ gen = generation[c]

ExactFamilyAuthority(slot, controller, gen) ==
  /\ slot \in FamilySlots
  /\ familyOpen
  /\ controller = familyController
  /\ gen = slotGeneration[slot]

FamilyAdmissionOpen == familyOpen /\ ~familyShutdown /\ ~familyTerminal

FamilyQuiescent ==
  \A slot \in FamilySlots :
    /\ ~slotLive[slot]
    /\ slotState[slot] \in {"free", "reapable"}

DesiredFamilyReady ==
  familyOpen /\ \A slot \in FamilySlots : slotState[slot] = "running"

AllOuterJoined ==
  \A c \in Children :
    ~childLive[c] /\ childState[c] \in {"configured", "joined"}

HigherAffectedSettled(c) ==
  \A other \in affected :
    Rank(other) > Rank(c) =>
      (~childLive[other] \/ childStop[other])

LowerAffectedRunning(c) ==
  \A other \in affected :
    Rank(other) < Rank(c) => childState[other] = "running"

Init ==
  /\ mode = "unconfigured"
  /\ shutdown = FALSE
  /\ terminal = FALSE
  /\ result = "none"
  /\ childState = [c \in Children |-> "configured"]
  /\ childLive = [c \in Children |-> FALSE]
  /\ childReady = [c \in Children |-> FALSE]
  /\ childStop = [c \in Children |-> FALSE]
  /\ childStuck = [c \in Children |-> FALSE]
  /\ generation = [c \in Children |-> 0]
  /\ joinedGeneration = [c \in Children |-> 0]
  /\ affected = {}
  /\ trigger = NoChild
  /\ recoveryImpact = NoImpact
  /\ incidentId = 0
  /\ incidentAttempt = 0
  /\ incidentActive = FALSE
  /\ childIncident = [c \in Children |-> 0]
  /\ childAttempt = [c \in Children |-> 0]
  /\ lastStopRank = 3
  /\ lastStartRank = 0
  /\ familyOpen = FALSE
  /\ familyController = 0
  /\ retiredControllers = {}
  /\ familyIncarnation = 0
  /\ familyShutdown = FALSE
  /\ familyTerminal = FALSE
  /\ slotState = [slot \in FamilySlots |-> "free"]
  /\ slotLive = [slot \in FamilySlots |-> FALSE]
  /\ slotReady = [slot \in FamilySlots |-> FALSE]
  /\ slotStop = [slot \in FamilySlots |-> FALSE]
  /\ slotRecover = [slot \in FamilySlots |-> FALSE]
  /\ slotGeneration = [slot \in FamilySlots |-> 0]
  /\ slotJoinedGeneration = [slot \in FamilySlots |-> 0]
  /\ nestedEscalation = FALSE
  /\ nestedIncident = 0
  /\ nestedAttempt = 0
  /\ staleCommandAccepted = FALSE
  /\ replacementBeforeJoin = FALSE
  /\ ownerPublishedWithoutReplay = FALSE
  /\ nestedIncidentMinted = FALSE

Configure ==
  /\ mode = "unconfigured"
  /\ mode' = "startup"
  /\ UNCHANGED <<shutdown, terminal, result,
                  childState, childLive, childReady, childStop, childStuck,
                  generation, joinedGeneration,
                  affected, trigger, recoveryImpact, incidentId,
                  incidentAttempt, incidentActive, childIncident,
                  childAttempt, lastStopRank, lastStartRank,
                  familyOpen, familyController, retiredControllers,
                  familyIncarnation, familyShutdown, familyTerminal,
                  slotState, slotLive, slotReady, slotStop, slotRecover,
                  slotGeneration, slotJoinedGeneration,
                  nestedEscalation, nestedIncident, nestedAttempt,
                  staleCommandAccepted, replacementBeforeJoin,
                  ownerPublishedWithoutReplay, nestedIncidentMinted>>

StartInitial(c) ==
  /\ mode = "startup"
  /\ c \in Children
  /\ childState[c] = "configured"
  /\ generation[c] < MaxGeneration
  /\ \A other \in Children :
       childState[other] = "configured" => Rank(c) <= Rank(other)
  /\ \A required \in Prerequisites(c) :
       childState[required] = "running"
  /\ childState' = [childState EXCEPT ![c] = "starting"]
  /\ childLive' = [childLive EXCEPT ![c] = TRUE]
  /\ childReady' = [childReady EXCEPT ![c] = FALSE]
  /\ childStop' = [childStop EXCEPT ![c] = FALSE]
  /\ generation' = [generation EXCEPT ![c] = @ + 1]
  /\ childIncident' = [childIncident EXCEPT ![c] = 0]
  /\ childAttempt' = [childAttempt EXCEPT ![c] = 0]
  /\ UNCHANGED <<mode, shutdown, terminal, result, childStuck,
                  joinedGeneration, affected, trigger, recoveryImpact,
                  incidentId, incidentAttempt, incidentActive,
                  lastStopRank, lastStartRank,
                  familyOpen, familyController, retiredControllers,
                  familyIncarnation, familyShutdown, familyTerminal,
                  slotState, slotLive, slotReady, slotStop, slotRecover,
                  slotGeneration, slotJoinedGeneration,
                  nestedEscalation, nestedIncident, nestedAttempt,
                  staleCommandAccepted, replacementBeforeJoin,
                  ownerPublishedWithoutReplay, nestedIncidentMinted>>

OpenNestedFamily ==
  /\ childState[Owner] = "starting"
  /\ childLive[Owner]
  /\ ~familyOpen
  /\ familyController < MaxController
  /\ familyOpen' = TRUE
  /\ familyController' = familyController + 1
  /\ familyIncarnation' = generation[Owner]
  /\ familyShutdown' = FALSE
  /\ familyTerminal' = FALSE
  /\ slotState' = [slot \in FamilySlots |-> "free"]
  /\ slotLive' = [slot \in FamilySlots |-> FALSE]
  /\ slotReady' = [slot \in FamilySlots |-> FALSE]
  /\ slotStop' = [slot \in FamilySlots |-> FALSE]
  /\ slotRecover' = [slot \in FamilySlots |-> FALSE]
  /\ slotGeneration' = [slot \in FamilySlots |-> 0]
  /\ slotJoinedGeneration' = [slot \in FamilySlots |-> 0]
  /\ UNCHANGED <<mode, shutdown, terminal, result,
                  childState, childLive, childReady, childStop, childStuck,
                  generation, joinedGeneration,
                  affected, trigger, recoveryImpact, incidentId,
                  incidentAttempt, incidentActive, childIncident,
                  childAttempt, lastStopRank, lastStartRank,
                  retiredControllers, nestedEscalation,
                  nestedIncident, nestedAttempt, staleCommandAccepted,
                  replacementBeforeJoin, ownerPublishedWithoutReplay,
                  nestedIncidentMinted>>

ReserveFamily(slot) ==
  /\ FamilyAdmissionOpen
  /\ slot \in FamilySlots
  /\ slotState[slot] \in {"free", "reapable"}
  /\ slotGeneration[slot] < MaxGeneration
  /\ slotState' = [slotState EXCEPT ![slot] = "reserved"]
  /\ slotGeneration' = [slotGeneration EXCEPT ![slot] = @ + 1]
  /\ slotReady' = [slotReady EXCEPT ![slot] = FALSE]
  /\ slotStop' = [slotStop EXCEPT ![slot] = FALSE]
  /\ slotRecover' = [slotRecover EXCEPT ![slot] = FALSE]
  /\ UNCHANGED <<mode, shutdown, terminal, result,
                  childState, childLive, childReady, childStop, childStuck,
                  generation, joinedGeneration,
                  affected, trigger, recoveryImpact, incidentId,
                  incidentAttempt, incidentActive, childIncident,
                  childAttempt, lastStopRank, lastStartRank,
                  familyOpen, familyController, retiredControllers,
                  familyIncarnation, familyShutdown, familyTerminal,
                  slotLive, slotJoinedGeneration,
                  nestedEscalation, nestedIncident, nestedAttempt,
                  staleCommandAccepted, replacementBeforeJoin,
                  ownerPublishedWithoutReplay, nestedIncidentMinted>>

CommitFamily(slot) ==
  /\ FamilyAdmissionOpen
  /\ slotState[slot] = "reserved"
  /\ slotState' = [slotState EXCEPT ![slot] = "queued"]
  /\ UNCHANGED <<mode, shutdown, terminal, result,
                  childState, childLive, childReady, childStop, childStuck,
                  generation, joinedGeneration,
                  affected, trigger, recoveryImpact, incidentId,
                  incidentAttempt, incidentActive, childIncident,
                  childAttempt, lastStopRank, lastStartRank,
                  familyOpen, familyController, retiredControllers,
                  familyIncarnation, familyShutdown, familyTerminal,
                  slotLive, slotReady, slotStop, slotRecover,
                  slotGeneration, slotJoinedGeneration,
                  nestedEscalation, nestedIncident, nestedAttempt,
                  staleCommandAccepted, replacementBeforeJoin,
                  ownerPublishedWithoutReplay, nestedIncidentMinted>>

RollbackFamily(slot) ==
  /\ slotState[slot] = "reserved"
  /\ slotState' = [slotState EXCEPT ![slot] = "free"]
  /\ UNCHANGED <<mode, shutdown, terminal, result,
                  childState, childLive, childReady, childStop, childStuck,
                  generation, joinedGeneration,
                  affected, trigger, recoveryImpact, incidentId,
                  incidentAttempt, incidentActive, childIncident,
                  childAttempt, lastStopRank, lastStartRank,
                  familyOpen, familyController, retiredControllers,
                  familyIncarnation, familyShutdown, familyTerminal,
                  slotLive, slotReady, slotStop, slotRecover,
                  slotGeneration, slotJoinedGeneration,
                  nestedEscalation, nestedIncident, nestedAttempt,
                  staleCommandAccepted, replacementBeforeJoin,
                  ownerPublishedWithoutReplay, nestedIncidentMinted>>

TakeFamilyStart(slot) ==
  /\ FamilyAdmissionOpen
  /\ slotState[slot] = "queued"
  /\ slotState' = [slotState EXCEPT ![slot] = "starting"]
  /\ slotLive' = [slotLive EXCEPT ![slot] = TRUE]
  /\ UNCHANGED <<mode, shutdown, terminal, result,
                  childState, childLive, childReady, childStop, childStuck,
                  generation, joinedGeneration,
                  affected, trigger, recoveryImpact, incidentId,
                  incidentAttempt, incidentActive, childIncident,
                  childAttempt, lastStopRank, lastStartRank,
                  familyOpen, familyController, retiredControllers,
                  familyIncarnation, familyShutdown, familyTerminal,
                  slotReady, slotStop, slotRecover,
                  slotGeneration, slotJoinedGeneration,
                  nestedEscalation, nestedIncident, nestedAttempt,
                  staleCommandAccepted, replacementBeforeJoin,
                  ownerPublishedWithoutReplay, nestedIncidentMinted>>

MarkFamilyReady(slot) ==
  /\ slotState[slot] = "starting"
  /\ slotLive[slot]
  /\ ~slotStop[slot]
  /\ slotState' = [slotState EXCEPT ![slot] = "running"]
  /\ slotReady' = [slotReady EXCEPT ![slot] = TRUE]
  /\ UNCHANGED <<mode, shutdown, terminal, result,
                  childState, childLive, childReady, childStop, childStuck,
                  generation, joinedGeneration,
                  affected, trigger, recoveryImpact, incidentId,
                  incidentAttempt, incidentActive, childIncident,
                  childAttempt, lastStopRank, lastStartRank,
                  familyOpen, familyController, retiredControllers,
                  familyIncarnation, familyShutdown, familyTerminal,
                  slotLive, slotStop, slotRecover,
                  slotGeneration, slotJoinedGeneration,
                  nestedEscalation, nestedIncident, nestedAttempt,
                  staleCommandAccepted, replacementBeforeJoin,
                  ownerPublishedWithoutReplay, nestedIncidentMinted>>

MarkOuterReady(c) ==
  /\ childState[c] = "starting"
  /\ childLive[c]
  /\ ~childStop[c]
  /\ (c # Owner \/ DesiredFamilyReady \/
       LifecyclePolicy = "owner-ready-before-readmission-broken")
  /\ childState' = [childState EXCEPT ![c] = "ready"]
  /\ childReady' = [childReady EXCEPT ![c] = TRUE]
  /\ ownerPublishedWithoutReplay' =
       (ownerPublishedWithoutReplay \/
          (c = Owner /\ ~DesiredFamilyReady))
  /\ UNCHANGED <<mode, shutdown, terminal, result,
                  childLive, childStop, childStuck,
                  generation, joinedGeneration,
                  affected, trigger, recoveryImpact, incidentId,
                  incidentAttempt, incidentActive, childIncident,
                  childAttempt, lastStopRank, lastStartRank,
                  familyOpen, familyController, retiredControllers,
                  familyIncarnation, familyShutdown, familyTerminal,
                  slotState, slotLive, slotReady, slotStop, slotRecover,
                  slotGeneration, slotJoinedGeneration,
                  nestedEscalation, nestedIncident, nestedAttempt,
                  staleCommandAccepted, replacementBeforeJoin,
                  nestedIncidentMinted>>

PublishOuter(c) ==
  /\ childState[c] = "ready"
  /\ \A required \in Prerequisites(c) :
       childState[required] = "running"
  /\ childState' = [childState EXCEPT ![c] = "running"]
  /\ UNCHANGED <<mode, shutdown, terminal, result,
                  childLive, childReady, childStop, childStuck,
                  generation, joinedGeneration,
                  affected, trigger, recoveryImpact, incidentId,
                  incidentAttempt, incidentActive, childIncident,
                  childAttempt, lastStopRank, lastStartRank,
                  familyOpen, familyController, retiredControllers,
                  familyIncarnation, familyShutdown, familyTerminal,
                  slotState, slotLive, slotReady, slotStop, slotRecover,
                  slotGeneration, slotJoinedGeneration,
                  nestedEscalation, nestedIncident, nestedAttempt,
                  staleCommandAccepted, replacementBeforeJoin,
                  ownerPublishedWithoutReplay, nestedIncidentMinted>>

FinishStartup ==
  /\ mode = "startup"
  /\ \A c \in Children : childState[c] = "running"
  /\ mode' = "running"
  /\ UNCHANGED <<shutdown, terminal, result,
                  childState, childLive, childReady, childStop, childStuck,
                  generation, joinedGeneration,
                  affected, trigger, recoveryImpact, incidentId,
                  incidentAttempt, incidentActive, childIncident,
                  childAttempt, lastStopRank, lastStartRank,
                  familyOpen, familyController, retiredControllers,
                  familyIncarnation, familyShutdown, familyTerminal,
                  slotState, slotLive, slotReady, slotStop, slotRecover,
                  slotGeneration, slotJoinedGeneration,
                  nestedEscalation, nestedIncident, nestedAttempt,
                  staleCommandAccepted, replacementBeforeJoin,
                  ownerPublishedWithoutReplay, nestedIncidentMinted>>

CanRecover(c, impact) ==
  /\ impact # "escalate"
  /\ NextAttempt(incidentActive, incidentAttempt) <= MaxAttempts
  /\ \A member \in AffectedFor(c, impact) :
       generation[member] < MaxGeneration

BeginRecoverableFailure(c, impact) ==
  LET next == NextAttempt(incidentActive, incidentAttempt) IN
  /\ mode = "running"
  /\ ~nestedEscalation
  /\ c \in Children
  /\ childState[c] = "running"
  /\ (c # Owner \/ (~familyOpen /\ ~nestedEscalation))
  /\ impact \in Impacts
  /\ CanRecover(c, impact)
  /\ mode' = "recovery-stop"
  /\ affected' = AffectedFor(c, impact)
  /\ trigger' = c
  /\ recoveryImpact' = impact
  /\ childState' = [childState EXCEPT ![c] = "terminated"]
  /\ childLive' = [childLive EXCEPT ![c] = FALSE]
  /\ childReady' = [childReady EXCEPT ![c] = FALSE]
  /\ childStop' = [childStop EXCEPT ![c] = FALSE]
  /\ incidentId' = IF incidentActive THEN incidentId ELSE incidentId + 1
  /\ incidentAttempt' = next
  /\ incidentActive' = TRUE
  /\ lastStopRank' = 3
  /\ lastStartRank' = 0
  /\ UNCHANGED <<shutdown, terminal, result, childStuck,
                  generation, joinedGeneration, childIncident, childAttempt,
                  familyOpen, familyController, retiredControllers,
                  familyIncarnation, familyShutdown, familyTerminal,
                  slotState, slotLive, slotReady, slotStop, slotRecover,
                  slotGeneration, slotJoinedGeneration,
                  nestedEscalation, nestedIncident, nestedAttempt,
                  staleCommandAccepted, replacementBeforeJoin,
                  ownerPublishedWithoutReplay, nestedIncidentMinted>>

BeginTerminalFailure(c, impact) ==
  /\ mode \in {"startup", "running"}
  /\ ~nestedEscalation
  /\ c \in Children
  /\ childState[c] \in {"starting", "ready", "running"}
  /\ (c # Owner \/ (~familyOpen /\ ~nestedEscalation))
  /\ impact \in Impacts
  /\ (mode = "startup" \/ ~CanRecover(c, impact))
  /\ mode' = "terminal-stop"
  /\ terminal' = TRUE
  /\ result' =
       IF mode = "startup" THEN "startup-failed"
       ELSE IF impact = "escalate" THEN "failure-escalated"
       ELSE "recovery-exhausted"
  /\ affected' = Children
  /\ trigger' = c
  /\ recoveryImpact' = impact
  /\ childState' = [childState EXCEPT ![c] = "terminated"]
  /\ childLive' = [childLive EXCEPT ![c] = FALSE]
  /\ childReady' = [childReady EXCEPT ![c] = FALSE]
  /\ childStop' = [childStop EXCEPT ![c] = FALSE]
  /\ incidentId' = IF incidentActive THEN incidentId ELSE incidentId + 1
  /\ incidentAttempt' =
       IF incidentActive THEN incidentAttempt ELSE 1
  /\ incidentActive' = TRUE
  /\ lastStopRank' = 3
  /\ lastStartRank' = 0
  /\ UNCHANGED <<shutdown, childStuck, generation, joinedGeneration,
                  childIncident, childAttempt,
                  familyOpen, familyController, retiredControllers,
                  familyIncarnation, familyShutdown, familyTerminal,
                  slotState, slotLive, slotReady, slotStop, slotRecover,
                  slotGeneration, slotJoinedGeneration,
                  nestedEscalation, nestedIncident, nestedAttempt,
                  staleCommandAccepted, replacementBeforeJoin,
                  ownerPublishedWithoutReplay, nestedIncidentMinted>>

OuterCommandAllowed(c, controller, gen) ==
  IF LifecyclePolicy = "stale-authority-broken"
  THEN c \in Children /\ gen = generation[c]
  ELSE ExactOuterAuthority(c, controller, gen)

ManualRestart(c, controller, gen, impact) ==
  LET next == NextAttempt(incidentActive, incidentAttempt) IN
  /\ mode = "running"
  /\ c \in Children
  /\ childState[c] = "running"
  /\ impact \in Impacts \ {"escalate"}
  /\ OuterCommandAllowed(c, controller, gen)
  /\ CanRecover(c, impact)
  /\ mode' = "recovery-stop"
  /\ affected' = AffectedFor(c, impact)
  /\ trigger' = c
  /\ recoveryImpact' = impact
  /\ incidentId' = IF incidentActive THEN incidentId ELSE incidentId + 1
  /\ incidentAttempt' = next
  /\ incidentActive' = TRUE
  /\ lastStopRank' = 3
  /\ lastStartRank' = 0
  /\ staleCommandAccepted' =
       staleCommandAccepted \/ ~ExactOuterAuthority(c, controller, gen)
  /\ UNCHANGED <<shutdown, terminal, result,
                  childState, childLive, childReady, childStop, childStuck,
                  generation, joinedGeneration, childIncident, childAttempt,
                  familyOpen, familyController, retiredControllers,
                  familyIncarnation, familyShutdown, familyTerminal,
                  slotState, slotLive, slotReady, slotStop, slotRecover,
                  slotGeneration, slotJoinedGeneration,
                  nestedEscalation, nestedIncident, nestedAttempt,
                  replacementBeforeJoin, ownerPublishedWithoutReplay,
                  nestedIncidentMinted>>

RequestShutdown ==
  /\ mode \notin {"unconfigured", "finished", "shutdown-stop",
                   "terminal-stop"}
  /\ shutdown' = TRUE
  /\ mode' = "shutdown-stop"
  /\ result' = "shutdown-completed"
  /\ affected' = Children
  /\ trigger' = NoChild
  /\ recoveryImpact' = NoImpact
  /\ lastStopRank' = 3
  /\ childReady' = [c \in Children |-> FALSE]
  /\ UNCHANGED <<terminal, childState, childLive, childStop, childStuck,
                  generation, joinedGeneration, incidentId,
                  incidentAttempt, incidentActive, childIncident,
                  childAttempt, lastStartRank,
                  familyOpen, familyController, retiredControllers,
                  familyIncarnation, familyShutdown, familyTerminal,
                  slotState, slotLive, slotReady, slotStop, slotRecover,
                  slotGeneration, slotJoinedGeneration,
                  nestedEscalation, nestedIncident, nestedAttempt,
                  staleCommandAccepted, replacementBeforeJoin,
                  ownerPublishedWithoutReplay, nestedIncidentMinted>>

IssueOuterStop(c) ==
  /\ mode \in {"recovery-stop", "shutdown-stop", "terminal-stop"}
  /\ c \in affected
  /\ childLive[c]
  /\ ~childStop[c]
  /\ HigherAffectedSettled(c)
  /\ Rank(c) < lastStopRank
  /\ childStop' = [childStop EXCEPT ![c] = TRUE]
  /\ childState' = [childState EXCEPT ![c] = "stopping"]
  /\ childReady' = [childReady EXCEPT ![c] = FALSE]
  /\ lastStopRank' = Rank(c)
  /\ UNCHANGED <<mode, shutdown, terminal, result,
                  childLive, childStuck, generation, joinedGeneration,
                  affected, trigger, recoveryImpact, incidentId,
                  incidentAttempt, incidentActive, childIncident,
                  childAttempt, lastStartRank,
                  familyOpen, familyController, retiredControllers,
                  familyIncarnation, familyShutdown, familyTerminal,
                  slotState, slotLive, slotReady, slotStop, slotRecover,
                  slotGeneration, slotJoinedGeneration,
                  nestedEscalation, nestedIncident, nestedAttempt,
                  staleCommandAccepted, replacementBeforeJoin,
                  ownerPublishedWithoutReplay, nestedIncidentMinted>>

ForwardParentStop ==
  /\ LifecyclePolicy # "no-parent-forwarding-broken"
  /\ familyOpen
  /\ childStop[Owner]
  /\ ~familyShutdown
  /\ familyShutdown' = TRUE
  /\ UNCHANGED <<mode, shutdown, terminal, result,
                  childState, childLive, childReady, childStop, childStuck,
                  generation, joinedGeneration,
                  affected, trigger, recoveryImpact, incidentId,
                  incidentAttempt, incidentActive, childIncident,
                  childAttempt, lastStopRank, lastStartRank,
                  familyOpen, familyController, retiredControllers,
                  familyIncarnation, familyTerminal,
                  slotState, slotLive, slotReady, slotStop, slotRecover,
                  slotGeneration, slotJoinedGeneration,
                  nestedEscalation, nestedIncident, nestedAttempt,
                  staleCommandAccepted, replacementBeforeJoin,
                  ownerPublishedWithoutReplay, nestedIncidentMinted>>

RequestFamilyShutdown ==
  /\ familyOpen
  /\ ~familyShutdown
  /\ familyShutdown' = TRUE
  /\ UNCHANGED <<mode, shutdown, terminal, result,
                  childState, childLive, childReady, childStop, childStuck,
                  generation, joinedGeneration,
                  affected, trigger, recoveryImpact, incidentId,
                  incidentAttempt, incidentActive, childIncident,
                  childAttempt, lastStopRank, lastStartRank,
                  familyOpen, familyController, retiredControllers,
                  familyIncarnation, familyTerminal,
                  slotState, slotLive, slotReady, slotStop, slotRecover,
                  slotGeneration, slotJoinedGeneration,
                  nestedEscalation, nestedIncident, nestedAttempt,
                  staleCommandAccepted, replacementBeforeJoin,
                  ownerPublishedWithoutReplay, nestedIncidentMinted>>

CancelFamilyPending(slot) ==
  /\ familyOpen
  /\ familyShutdown
  /\ slotState[slot] \in {"reserved", "queued", "backing-off"}
  /\ slotState' =
       [slotState EXCEPT
          ![slot] = IF @ = "reserved" THEN "free" ELSE "reapable"]
  /\ slotLive' = [slotLive EXCEPT ![slot] = FALSE]
  /\ slotReady' = [slotReady EXCEPT ![slot] = FALSE]
  /\ slotStop' = [slotStop EXCEPT ![slot] = TRUE]
  /\ slotRecover' = [slotRecover EXCEPT ![slot] = FALSE]
  /\ UNCHANGED <<mode, shutdown, terminal, result,
                  childState, childLive, childReady, childStop, childStuck,
                  generation, joinedGeneration,
                  affected, trigger, recoveryImpact, incidentId,
                  incidentAttempt, incidentActive, childIncident,
                  childAttempt, lastStopRank, lastStartRank,
                  familyOpen, familyController, retiredControllers,
                  familyIncarnation, familyShutdown, familyTerminal,
                  slotGeneration, slotJoinedGeneration,
                  nestedEscalation, nestedIncident, nestedAttempt,
                  staleCommandAccepted, replacementBeforeJoin,
                  ownerPublishedWithoutReplay, nestedIncidentMinted>>

StopFamilySlot(slot) ==
  /\ familyOpen
  /\ familyShutdown
  /\ slotState[slot] \in {"starting", "running"}
  /\ slotLive[slot]
  /\ slotState' = [slotState EXCEPT ![slot] = "stopping"]
  /\ slotReady' = [slotReady EXCEPT ![slot] = FALSE]
  /\ slotStop' = [slotStop EXCEPT ![slot] = TRUE]
  /\ slotRecover' = [slotRecover EXCEPT ![slot] = FALSE]
  /\ UNCHANGED <<mode, shutdown, terminal, result,
                  childState, childLive, childReady, childStop, childStuck,
                  generation, joinedGeneration,
                  affected, trigger, recoveryImpact, incidentId,
                  incidentAttempt, incidentActive, childIncident,
                  childAttempt, lastStopRank, lastStartRank,
                  familyOpen, familyController, retiredControllers,
                  familyIncarnation, familyShutdown, familyTerminal,
                  slotLive, slotGeneration, slotJoinedGeneration,
                  nestedEscalation, nestedIncident, nestedAttempt,
                  staleCommandAccepted, replacementBeforeJoin,
                  ownerPublishedWithoutReplay, nestedIncidentMinted>>

TerminateFamilySlot(slot) ==
  /\ slotState[slot] = "stopping"
  /\ slotLive[slot]
  /\ slotState' = [slotState EXCEPT ![slot] = "terminated"]
  /\ slotLive' = [slotLive EXCEPT ![slot] = FALSE]
  /\ slotReady' = [slotReady EXCEPT ![slot] = FALSE]
  /\ UNCHANGED <<mode, shutdown, terminal, result,
                  childState, childLive, childReady, childStop, childStuck,
                  generation, joinedGeneration,
                  affected, trigger, recoveryImpact, incidentId,
                  incidentAttempt, incidentActive, childIncident,
                  childAttempt, lastStopRank, lastStartRank,
                  familyOpen, familyController, retiredControllers,
                  familyIncarnation, familyShutdown, familyTerminal,
                  slotStop, slotRecover, slotGeneration,
                  slotJoinedGeneration, nestedEscalation,
                  nestedIncident, nestedAttempt, staleCommandAccepted,
                  replacementBeforeJoin, ownerPublishedWithoutReplay,
                  nestedIncidentMinted>>

JoinFamilySlot(slot) ==
  /\ slotState[slot] = "terminated"
  /\ ~slotLive[slot]
  /\ slotJoinedGeneration' =
       [slotJoinedGeneration EXCEPT ![slot] = slotGeneration[slot]]
  /\ slotState' =
       [slotState EXCEPT
          ![slot] = IF slotRecover[slot] /\ ~familyShutdown
                   THEN "backing-off" ELSE "reapable"]
  /\ slotRecover' =
       [slotRecover EXCEPT
          ![slot] = IF @ /\ ~familyShutdown THEN TRUE ELSE FALSE]
  /\ UNCHANGED <<mode, shutdown, terminal, result,
                  childState, childLive, childReady, childStop, childStuck,
                  generation, joinedGeneration,
                  affected, trigger, recoveryImpact, incidentId,
                  incidentAttempt, incidentActive, childIncident,
                  childAttempt, lastStopRank, lastStartRank,
                  familyOpen, familyController, retiredControllers,
                  familyIncarnation, familyShutdown, familyTerminal,
                  slotLive, slotReady, slotStop, slotGeneration,
                  nestedEscalation, nestedIncident, nestedAttempt,
                  staleCommandAccepted, replacementBeforeJoin,
                  ownerPublishedWithoutReplay, nestedIncidentMinted>>

RestartFamilySlot(slot) ==
  /\ FamilyAdmissionOpen
  /\ slotState[slot] = "backing-off"
  /\ slotGeneration[slot] < MaxGeneration
  /\ slotJoinedGeneration[slot] = slotGeneration[slot]
  /\ slotState' = [slotState EXCEPT ![slot] = "starting"]
  /\ slotLive' = [slotLive EXCEPT ![slot] = TRUE]
  /\ slotReady' = [slotReady EXCEPT ![slot] = FALSE]
  /\ slotStop' = [slotStop EXCEPT ![slot] = FALSE]
  /\ slotRecover' = [slotRecover EXCEPT ![slot] = FALSE]
  /\ slotGeneration' = [slotGeneration EXCEPT ![slot] = @ + 1]
  /\ UNCHANGED <<mode, shutdown, terminal, result,
                  childState, childLive, childReady, childStop, childStuck,
                  generation, joinedGeneration,
                  affected, trigger, recoveryImpact, incidentId,
                  incidentAttempt, incidentActive, childIncident,
                  childAttempt, lastStopRank, lastStartRank,
                  familyOpen, familyController, retiredControllers,
                  familyIncarnation, familyShutdown, familyTerminal,
                  slotJoinedGeneration, nestedEscalation,
                  nestedIncident, nestedAttempt, staleCommandAccepted,
                  replacementBeforeJoin, ownerPublishedWithoutReplay,
                  nestedIncidentMinted>>

FailFamilySlot(slot) ==
  /\ FamilyAdmissionOpen
  /\ slotState[slot] = "running"
  /\ slotLive[slot]
  /\ slotGeneration[slot] < MaxGeneration
  /\ slotState' = [slotState EXCEPT ![slot] = "terminated"]
  /\ slotLive' = [slotLive EXCEPT ![slot] = FALSE]
  /\ slotReady' = [slotReady EXCEPT ![slot] = FALSE]
  /\ slotRecover' = [slotRecover EXCEPT ![slot] = TRUE]
  /\ UNCHANGED <<mode, shutdown, terminal, result,
                  childState, childLive, childReady, childStop, childStuck,
                  generation, joinedGeneration,
                  affected, trigger, recoveryImpact, incidentId,
                  incidentAttempt, incidentActive, childIncident,
                  childAttempt, lastStopRank, lastStartRank,
                  familyOpen, familyController, retiredControllers,
                  familyIncarnation, familyShutdown, familyTerminal,
                  slotStop, slotGeneration, slotJoinedGeneration,
                  nestedEscalation, nestedIncident, nestedAttempt,
                  staleCommandAccepted, replacementBeforeJoin,
                  ownerPublishedWithoutReplay, nestedIncidentMinted>>

EscalateFamilySlot(slot) ==
  /\ mode = "running"
  /\ FamilyAdmissionOpen
  /\ slotState[slot] = "running"
  /\ slotLive[slot]
  /\ slotState' = [slotState EXCEPT ![slot] = "terminated"]
  /\ slotLive' = [slotLive EXCEPT ![slot] = FALSE]
  /\ slotReady' = [slotReady EXCEPT ![slot] = FALSE]
  /\ slotRecover' = [slotRecover EXCEPT ![slot] = FALSE]
  /\ familyTerminal' = TRUE
  /\ familyShutdown' = TRUE
  /\ nestedEscalation' = TRUE
  /\ nestedIncident' = IF incidentActive THEN incidentId ELSE incidentId + 1
  /\ nestedAttempt' = IF incidentActive THEN incidentAttempt ELSE 1
  /\ UNCHANGED <<mode, shutdown, terminal, result,
                  childState, childLive, childReady, childStop, childStuck,
                  generation, joinedGeneration,
                  affected, trigger, recoveryImpact, incidentId,
                  incidentAttempt, incidentActive,
                  childIncident, childAttempt, lastStopRank, lastStartRank,
                  familyOpen, familyController, retiredControllers,
                  familyIncarnation, slotStop, slotGeneration,
                  slotJoinedGeneration, staleCommandAccepted,
                  replacementBeforeJoin, ownerPublishedWithoutReplay,
                  nestedIncidentMinted>>

FamilyCommandAllowed(slot, controller, gen) ==
  IF LifecyclePolicy = "stale-authority-broken"
  THEN slot \in FamilySlots /\ gen = slotGeneration[slot]
  ELSE ExactFamilyAuthority(slot, controller, gen)

StopFamilyByHandle(slot, controller, gen) ==
  /\ FamilyCommandAllowed(slot, controller, gen)
  /\ slotState[slot] \in {"queued", "starting", "running"}
  /\ ~familyShutdown
  /\ slotState' =
       [slotState EXCEPT
          ![slot] = IF @ = "queued" THEN "reapable" ELSE "stopping"]
  /\ slotReady' = [slotReady EXCEPT ![slot] = FALSE]
  /\ slotStop' = [slotStop EXCEPT ![slot] = TRUE]
  /\ slotRecover' = [slotRecover EXCEPT ![slot] = FALSE]
  /\ slotLive' =
       [slotLive EXCEPT ![slot] = IF slotState[slot] = "queued" THEN FALSE ELSE @]
  /\ staleCommandAccepted' =
       (staleCommandAccepted \/
          ~ExactFamilyAuthority(slot, controller, gen))
  /\ UNCHANGED <<mode, shutdown, terminal, result,
                  childState, childLive, childReady, childStop, childStuck,
                  generation, joinedGeneration,
                  affected, trigger, recoveryImpact, incidentId,
                  incidentAttempt, incidentActive, childIncident,
                  childAttempt, lastStopRank, lastStartRank,
                  familyOpen, familyController, retiredControllers,
                  familyIncarnation, familyShutdown, familyTerminal,
                  slotGeneration, slotJoinedGeneration,
                  nestedEscalation, nestedIncident, nestedAttempt,
                  replacementBeforeJoin, ownerPublishedWithoutReplay,
                  nestedIncidentMinted>>

CloseNestedFamily ==
  /\ familyOpen
  /\ (familyShutdown \/ familyTerminal)
  /\ FamilyQuiescent
  /\ familyOpen' = FALSE
  /\ retiredControllers' = retiredControllers \cup {familyController}
  /\ UNCHANGED <<mode, shutdown, terminal, result,
                  childState, childLive, childReady, childStop, childStuck,
                  generation, joinedGeneration,
                  affected, trigger, recoveryImpact, incidentId,
                  incidentAttempt, incidentActive, childIncident,
                  childAttempt, lastStopRank, lastStartRank,
                  familyController, familyIncarnation,
                  familyShutdown, familyTerminal,
                  slotState, slotLive, slotReady, slotStop, slotRecover,
                  slotGeneration, slotJoinedGeneration,
                  nestedEscalation, nestedIncident, nestedAttempt,
                  staleCommandAccepted, replacementBeforeJoin,
                  ownerPublishedWithoutReplay, nestedIncidentMinted>>

PropagateNestedEscalation ==
  LET propagatedId ==
        IF LifecyclePolicy = "nested-incident-mint-broken"
        THEN nestedIncident + 1
        ELSE nestedIncident
  IN
  /\ nestedEscalation
  /\ ~familyOpen
  /\ mode = "running"
  /\ childState[Owner] = "running"
  /\ childState' = [childState EXCEPT ![Owner] = "terminated"]
  /\ childLive' = [childLive EXCEPT ![Owner] = FALSE]
  /\ childReady' = [childReady EXCEPT ![Owner] = FALSE]
  /\ affected' = {Owner}
  /\ trigger' = Owner
  /\ recoveryImpact' = "isolate"
  /\ mode' = "recovery-stop"
  /\ lastStopRank' = 3
  /\ lastStartRank' = 0
  /\ nestedEscalation' = FALSE
  /\ incidentId' = propagatedId
  /\ incidentAttempt' = nestedAttempt
  /\ incidentActive' = TRUE
  /\ nestedIncidentMinted' =
       (nestedIncidentMinted \/ propagatedId # nestedIncident)
  /\ UNCHANGED <<shutdown, terminal, result, childStop, childStuck,
                  generation, joinedGeneration, childIncident, childAttempt,
                  familyOpen, familyController,
                  retiredControllers, familyIncarnation,
                  familyShutdown, familyTerminal,
                  slotState, slotLive, slotReady, slotStop, slotRecover,
                  slotGeneration, slotJoinedGeneration,
                  nestedIncident, nestedAttempt, staleCommandAccepted,
                  replacementBeforeJoin, ownerPublishedWithoutReplay>>

TerminateOuter(c) ==
  /\ c \in Children
  /\ childState[c] = "stopping"
  /\ childLive[c]
  /\ (c # Owner \/ ~familyOpen)
  /\ childState' = [childState EXCEPT ![c] = "terminated"]
  /\ childLive' = [childLive EXCEPT ![c] = FALSE]
  /\ childReady' = [childReady EXCEPT ![c] = FALSE]
  /\ UNCHANGED <<mode, shutdown, terminal, result,
                  childStop, childStuck, generation, joinedGeneration,
                  affected, trigger, recoveryImpact, incidentId,
                  incidentAttempt, incidentActive, childIncident,
                  childAttempt, lastStopRank, lastStartRank,
                  familyOpen, familyController, retiredControllers,
                  familyIncarnation, familyShutdown, familyTerminal,
                  slotState, slotLive, slotReady, slotStop, slotRecover,
                  slotGeneration, slotJoinedGeneration,
                  nestedEscalation, nestedIncident, nestedAttempt,
                  staleCommandAccepted, replacementBeforeJoin,
                  ownerPublishedWithoutReplay, nestedIncidentMinted>>

JoinOuter(c) ==
  /\ c \in Children
  /\ childState[c] = "terminated"
  /\ ~childLive[c]
  /\ childState' = [childState EXCEPT ![c] = "joined"]
  /\ joinedGeneration' =
       [joinedGeneration EXCEPT ![c] = generation[c]]
  /\ UNCHANGED <<mode, shutdown, terminal, result,
                  childLive, childReady, childStop, childStuck,
                  generation, affected, trigger, recoveryImpact,
                  incidentId, incidentAttempt, incidentActive,
                  childIncident, childAttempt, lastStopRank, lastStartRank,
                  familyOpen, familyController, retiredControllers,
                  familyIncarnation, familyShutdown, familyTerminal,
                  slotState, slotLive, slotReady, slotStop, slotRecover,
                  slotGeneration, slotJoinedGeneration,
                  nestedEscalation, nestedIncident, nestedAttempt,
                  staleCommandAccepted, replacementBeforeJoin,
                  ownerPublishedWithoutReplay, nestedIncidentMinted>>

BeginRecoveryBackoff ==
  /\ mode = "recovery-stop"
  /\ \A c \in affected :
       \/ childState[c] = "joined"
       \/ /\ LifecyclePolicy = "restart-before-join-broken"
          /\ childState[c] = "terminated"
  /\ mode' = "recovery-backoff"
  /\ UNCHANGED <<shutdown, terminal, result,
                  childState, childLive, childReady, childStop, childStuck,
                  generation, joinedGeneration,
                  affected, trigger, recoveryImpact, incidentId,
                  incidentAttempt, incidentActive, childIncident,
                  childAttempt, lastStopRank, lastStartRank,
                  familyOpen, familyController, retiredControllers,
                  familyIncarnation, familyShutdown, familyTerminal,
                  slotState, slotLive, slotReady, slotStop, slotRecover,
                  slotGeneration, slotJoinedGeneration,
                  nestedEscalation, nestedIncident, nestedAttempt,
                  staleCommandAccepted, replacementBeforeJoin,
                  ownerPublishedWithoutReplay, nestedIncidentMinted>>

FinishRecoveryBackoff ==
  /\ mode = "recovery-backoff"
  /\ mode' = "recovery-start"
  /\ lastStartRank' = 0
  /\ UNCHANGED <<shutdown, terminal, result,
                  childState, childLive, childReady, childStop, childStuck,
                  generation, joinedGeneration,
                  affected, trigger, recoveryImpact, incidentId,
                  incidentAttempt, incidentActive, childIncident,
                  childAttempt, lastStopRank,
                  familyOpen, familyController, retiredControllers,
                  familyIncarnation, familyShutdown, familyTerminal,
                  slotState, slotLive, slotReady, slotStop, slotRecover,
                  slotGeneration, slotJoinedGeneration,
                  nestedEscalation, nestedIncident, nestedAttempt,
                  staleCommandAccepted, replacementBeforeJoin,
                  ownerPublishedWithoutReplay, nestedIncidentMinted>>

StartReplacement(c) ==
  /\ mode = "recovery-start"
  /\ c \in affected
  /\ generation[c] < MaxGeneration
  /\ (childState[c] = "joined"
       \/ (LifecyclePolicy = "restart-before-join-broken"
           /\ childState[c] = "terminated"))
  /\ LowerAffectedRunning(c)
  /\ \A required \in Prerequisites(c) :
       childState[required] = "running"
  /\ childState' = [childState EXCEPT ![c] = "starting"]
  /\ childLive' = [childLive EXCEPT ![c] = TRUE]
  /\ childReady' = [childReady EXCEPT ![c] = FALSE]
  /\ childStop' = [childStop EXCEPT ![c] = FALSE]
  /\ childStuck' = [childStuck EXCEPT ![c] = FALSE]
  /\ generation' = [generation EXCEPT ![c] = @ + 1]
  /\ childIncident' = [childIncident EXCEPT ![c] = incidentId]
  /\ childAttempt' = [childAttempt EXCEPT ![c] = incidentAttempt]
  /\ lastStartRank' = Rank(c)
  /\ replacementBeforeJoin' =
       replacementBeforeJoin \/ childState[c] # "joined"
  /\ UNCHANGED <<mode, shutdown, terminal, result, joinedGeneration,
                  affected, trigger, recoveryImpact, incidentId,
                  incidentAttempt, incidentActive, lastStopRank,
                  familyOpen, familyController, retiredControllers,
                  familyIncarnation, familyShutdown, familyTerminal,
                  slotState, slotLive, slotReady, slotStop, slotRecover,
                  slotGeneration, slotJoinedGeneration,
                  nestedEscalation, nestedIncident, nestedAttempt,
                  staleCommandAccepted, ownerPublishedWithoutReplay,
                  nestedIncidentMinted>>

FinishRecovery ==
  /\ mode = "recovery-start"
  /\ \A c \in affected : childState[c] = "running"
  /\ mode' = "running"
  /\ affected' = {}
  /\ trigger' = NoChild
  /\ recoveryImpact' = NoImpact
  /\ lastStopRank' = 3
  /\ lastStartRank' = 0
  /\ UNCHANGED <<shutdown, terminal, result,
                  childState, childLive, childReady, childStop, childStuck,
                  generation, joinedGeneration, incidentId,
                  incidentAttempt, incidentActive, childIncident,
                  childAttempt, familyOpen, familyController,
                  retiredControllers, familyIncarnation,
                  familyShutdown, familyTerminal,
                  slotState, slotLive, slotReady, slotStop, slotRecover,
                  slotGeneration, slotJoinedGeneration,
                  nestedEscalation, nestedIncident, nestedAttempt,
                  staleCommandAccepted, replacementBeforeJoin,
                  ownerPublishedWithoutReplay, nestedIncidentMinted>>

CloseStableIncident ==
  /\ mode = "running"
  /\ incidentActive
  /\ ~nestedEscalation
  /\ incidentActive' = FALSE
  /\ incidentAttempt' = 0
  /\ UNCHANGED <<mode, shutdown, terminal, result,
                  childState, childLive, childReady, childStop, childStuck,
                  generation, joinedGeneration,
                  affected, trigger, recoveryImpact, incidentId,
                  childIncident, childAttempt, lastStopRank, lastStartRank,
                  familyOpen, familyController, retiredControllers,
                  familyIncarnation, familyShutdown, familyTerminal,
                  slotState, slotLive, slotReady, slotStop, slotRecover,
                  slotGeneration, slotJoinedGeneration,
                  nestedEscalation, nestedIncident, nestedAttempt,
                  staleCommandAccepted, replacementBeforeJoin,
                  ownerPublishedWithoutReplay, nestedIncidentMinted>>

BecomeStuck(c) ==
  /\ mode \in {"recovery-stop", "shutdown-stop", "terminal-stop"}
  /\ childState[c] = "stopping"
  /\ childLive[c]
  /\ childStuck' = [childStuck EXCEPT ![c] = TRUE]
  /\ terminal' = TRUE
  /\ mode' = "terminal-stop"
  /\ result' = "child-stuck"
  /\ UNCHANGED <<shutdown, childState, childLive, childReady, childStop,
                  generation, joinedGeneration, affected, trigger,
                  recoveryImpact, incidentId, incidentAttempt,
                  incidentActive, childIncident, childAttempt,
                  lastStopRank, lastStartRank,
                  familyOpen, familyController, retiredControllers,
                  familyIncarnation, familyShutdown, familyTerminal,
                  slotState, slotLive, slotReady, slotStop, slotRecover,
                  slotGeneration, slotJoinedGeneration,
                  nestedEscalation, nestedIncident, nestedAttempt,
                  staleCommandAccepted, replacementBeforeJoin,
                  ownerPublishedWithoutReplay, nestedIncidentMinted>>

FinishRun ==
  /\ mode \in {"shutdown-stop", "terminal-stop"}
  /\ AllOuterJoined
  /\ ~familyOpen
  /\ ~(\E c \in Children : childStuck[c])
  /\ mode' = "finished"
  /\ UNCHANGED <<shutdown, terminal, result,
                  childState, childLive, childReady, childStop, childStuck,
                  generation, joinedGeneration,
                  affected, trigger, recoveryImpact, incidentId,
                  incidentAttempt, incidentActive, childIncident,
                  childAttempt, lastStopRank, lastStartRank,
                  familyOpen, familyController, retiredControllers,
                  familyIncarnation, familyShutdown, familyTerminal,
                  slotState, slotLive, slotReady, slotStop, slotRecover,
                  slotGeneration, slotJoinedGeneration,
                  nestedEscalation, nestedIncident, nestedAttempt,
                  staleCommandAccepted, replacementBeforeJoin,
                  ownerPublishedWithoutReplay, nestedIncidentMinted>>

StartupAndServiceActions ==
  Configure
  \/ \E c \in Children : StartInitial(c) \/ MarkOuterReady(c)
                               \/ PublishOuter(c)
  \/ OpenNestedFamily
  \/ \E slot \in FamilySlots :
       ReserveFamily(slot) \/ CommitFamily(slot) \/ RollbackFamily(slot)
         \/ TakeFamilyStart(slot) \/ MarkFamilyReady(slot)
         \/ FailFamilySlot(slot) \/ EscalateFamilySlot(slot)
         \/ RestartFamilySlot(slot)
  \/ FinishStartup

FailureAndCommandActions ==
  \/ \E c \in Children, impact \in Impacts :
       BeginRecoverableFailure(c, impact) \/ BeginTerminalFailure(c, impact)
  \/ \E c \in Children, controller \in 0 .. MaxController,
        gen \in 0 .. MaxGeneration, impact \in Impacts \ {"escalate"} :
       ManualRestart(c, controller, gen, impact)
  \/ \E slot \in FamilySlots, controller \in 0 .. MaxController,
        gen \in 0 .. MaxGeneration :
       StopFamilyByHandle(slot, controller, gen)

FamilyDrainActions ==
  ForwardParentStop \/ RequestFamilyShutdown
  \/ \E slot \in FamilySlots :
       CancelFamilyPending(slot) \/ StopFamilySlot(slot)
         \/ TerminateFamilySlot(slot) \/ JoinFamilySlot(slot)
  \/ CloseNestedFamily \/ PropagateNestedEscalation

OuterProgressActions ==
  RequestShutdown
  \/ (\E c \in Children :
        IssueOuterStop(c) \/ TerminateOuter(c) \/ JoinOuter(c)
          \/ BecomeStuck(c))
  \/ BeginRecoveryBackoff \/ FinishRecoveryBackoff
  \/ (\E c \in Children : StartReplacement(c))
  \/ FinishRecovery \/ CloseStableIncident \/ FinishRun

Next ==
  StartupAndServiceActions \/ FailureAndCommandActions
    \/ FamilyDrainActions \/ OuterProgressActions

Spec == Init /\ [][Next]_vars

(***************************************************************************
The cooperative specification omits the deliberate stuck outcome.  Once a
shutdown is requested, ShutdownProgress is continuously enabled until every
nested and outer generation joins.  Weak fairness therefore states the same
conditional liveness contract as the implementation: cooperative children
eventually let synchronous Run return, while a stuck child has no such claim.
***************************************************************************)

ShutdownProgress ==
  (\E c \in Children :
     IssueOuterStop(c) \/ TerminateOuter(c) \/ JoinOuter(c))
  \/ ForwardParentStop
  \/ (\E slot \in FamilySlots :
       CancelFamilyPending(slot) \/ StopFamilySlot(slot)
         \/ TerminateFamilySlot(slot) \/ JoinFamilySlot(slot))
  \/ CloseNestedFamily \/ FinishRun

CooperativeOuterProgressActions ==
  RequestShutdown
  \/ (\E c \in Children :
        IssueOuterStop(c) \/ TerminateOuter(c) \/ JoinOuter(c))
  \/ BeginRecoveryBackoff \/ FinishRecoveryBackoff
  \/ (\E c \in Children : StartReplacement(c))
  \/ FinishRecovery \/ CloseStableIncident \/ FinishRun

CooperativeNext ==
  StartupAndServiceActions \/ FailureAndCommandActions
    \/ FamilyDrainActions \/ CooperativeOuterProgressActions

CooperativeSpec ==
  Init /\ [][CooperativeNext]_vars /\ WF_vars(ShutdownProgress)

CooperativeShutdownCompletes == shutdown ~> (mode = "finished")

TypeOK ==
  /\ mode \in Modes
  /\ shutdown \in BOOLEAN
  /\ terminal \in BOOLEAN
  /\ result \in Results
  /\ childState \in [Children -> OuterStates]
  /\ childLive \in [Children -> BOOLEAN]
  /\ childReady \in [Children -> BOOLEAN]
  /\ childStop \in [Children -> BOOLEAN]
  /\ childStuck \in [Children -> BOOLEAN]
  /\ generation \in [Children -> 0 .. MaxGeneration]
  /\ joinedGeneration \in [Children -> 0 .. MaxGeneration]
  /\ affected \subseteq Children
  /\ trigger \in Children \cup {NoChild}
  /\ recoveryImpact \in Impacts \cup {NoImpact}
  /\ incidentId \in 0 .. (MaxGeneration + MaxAttempts + 1)
  /\ incidentAttempt \in 0 .. MaxAttempts
  /\ incidentActive \in BOOLEAN
  /\ childIncident \in
       [Children -> 0 .. (MaxGeneration + MaxAttempts + 1)]
  /\ childAttempt \in [Children -> 0 .. MaxAttempts]
  /\ lastStopRank \in 1 .. 3
  /\ lastStartRank \in 0 .. 2
  /\ familyOpen \in BOOLEAN
  /\ familyController \in 0 .. MaxController
  /\ retiredControllers \subseteq 1 .. MaxController
  /\ familyIncarnation \in 0 .. MaxGeneration
  /\ familyShutdown \in BOOLEAN
  /\ familyTerminal \in BOOLEAN
  /\ slotState \in [FamilySlots -> FamilyStates]
  /\ slotLive \in [FamilySlots -> BOOLEAN]
  /\ slotReady \in [FamilySlots -> BOOLEAN]
  /\ slotStop \in [FamilySlots -> BOOLEAN]
  /\ slotRecover \in [FamilySlots -> BOOLEAN]
  /\ slotGeneration \in [FamilySlots -> 0 .. MaxGeneration]
  /\ slotJoinedGeneration \in [FamilySlots -> 0 .. MaxGeneration]
  /\ nestedEscalation \in BOOLEAN
  /\ nestedIncident \in 0 .. (MaxGeneration + MaxAttempts + 1)
  /\ nestedAttempt \in 0 .. MaxAttempts
  /\ staleCommandAccepted \in BOOLEAN
  /\ replacementBeforeJoin \in BOOLEAN
  /\ ownerPublishedWithoutReplay \in BOOLEAN
  /\ nestedIncidentMinted \in BOOLEAN

ReadyImpliesLive ==
  /\ \A c \in Children : childReady[c] => childLive[c]
  /\ \A slot \in FamilySlots : slotReady[slot] => slotLive[slot]

LifecycleStateMatchesOwnership ==
  /\ \A c \in Children :
       childLive[c] =
         (childState[c] \in {"starting", "ready", "running", "stopping"})
  /\ \A slot \in FamilySlots :
       slotLive[slot] =
         (slotState[slot] \in {"starting", "running", "stopping"})

JoinedMeansQuiescent ==
  \A c \in Children : childState[c] = "joined" =>
    /\ ~childLive[c]
    /\ joinedGeneration[c] = generation[c]

ReplacementFollowsJoin ==
  /\ ~replacementBeforeJoin
  /\ \A c \in Children :
       childLive[c] /\ generation[c] > 1 =>
         joinedGeneration[c] = generation[c] - 1

FamilyBackoffFollowsJoin ==
  \A slot \in FamilySlots :
    slotState[slot] = "backing-off" =>
      slotJoinedGeneration[slot] = slotGeneration[slot]

NoStaleCommandAccepted == ~staleCommandAccepted

StopOrderIsReverse ==
  mode \in {"recovery-stop", "shutdown-stop", "terminal-stop"} =>
    \A c \in affected :
      Rank(c) > lastStopRank => (~childLive[c] \/ childStop[c])

StartOrderIsTopological ==
  mode = "recovery-start" =>
    \A c \in affected :
      Rank(c) < lastStartRank => childState[c] = "running"

AffectedSetIsExact ==
  mode \in {"recovery-stop", "recovery-backoff", "recovery-start"} =>
    affected = AffectedFor(trigger, recoveryImpact)

AttemptIsBounded ==
  /\ incidentAttempt <= MaxAttempts
  /\ \A c \in Children : childAttempt[c] <= MaxAttempts

ReplacementSharesIncident ==
  mode = "recovery-start" =>
    \A c \in affected :
      childState[c] \in {"starting", "ready", "running"} =>
        /\ childIncident[c] = incidentId
        /\ childAttempt[c] = incidentAttempt

NestedEscalationPreservesIncident ==
  ~nestedIncidentMinted

OwnerReadinessFollowsReadmission == ~ownerPublishedWithoutReplay

FamilyControllerIsFresh ==
  familyOpen =>
    /\ familyController \notin retiredControllers
    /\ familyController # 0
    /\ familyIncarnation = generation[Owner]

ClosedFamilyIsQuiescent == ~familyOpen => FamilyQuiescent

NestedFamilyJoinsBeforeOwner ==
  childState[Owner] \in {"terminated", "joined"} => ~familyOpen

ShutdownPreventsRecovery ==
  shutdown => mode \notin
    {"recovery-stop", "recovery-backoff", "recovery-start"}

FinishedMeansJoined ==
  mode = "finished" =>
    /\ AllOuterJoined
    /\ ~familyOpen
    /\ ~(\E c \in Children : childStuck[c])

StuckPreventsReturn ==
  (\E c \in Children : childStuck[c]) => mode # "finished"

=============================================================================
