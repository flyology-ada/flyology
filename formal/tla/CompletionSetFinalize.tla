----------------------- MODULE CompletionSetFinalize -----------------------
EXTENDS Naturals

CONSTANTS DrainMode,
          DriverCloseMode,
          CleanupCloseMode,
          CleanupDispatchMode,
          CleanupHandoffMode,
          DriverRaiseMode,
          InitialOtherReported,
          ATCMode,
          ATCKind,
          ATCReturn

ASSUME DrainMode \in {"UserGate", "TargetGate"}
ASSUME DriverCloseMode \in {"Blocking", "Deferred"}
ASSUME CleanupCloseMode \in {"Blocking", "Deferred"}
ASSUME CleanupDispatchMode \in {"Atomic", "Split"}
ASSUME CleanupHandoffMode \in {"Atomic", "Split"}
ASSUME DriverRaiseMode \in {"Escape", "Terminalize"}
ASSUME InitialOtherReported \in BOOLEAN
\* These constants select qualification scenarios, not provider policy.
ASSUME ATCMode \in {"Disabled", "Deferred", "Split"}
ASSUME ATCKind \in {"Batch", "Stabilizer"}
ASSUME ATCReturn \in {"Terminal", "Rearm"}

VARIABLES targetState,
          targetReported,
          otherState,
          otherReported,
          savedOtherReported,
          cancellationRequested,
          phase,
          driverState,
          peerRegistered,
          closeRequired,
          closePending,
          driverReturned,
          driverPhase,
          raiseRootState,
          raiseRootSource,
          raiseRootHasChild,
          driverRaised,
          terminalFailureCount,
          raisePhase,
          harnessPhase,
          lastAction,
          atc

vars ==
    <<targetState,
      targetReported,
      otherState,
      otherReported,
      savedOtherReported,
      cancellationRequested,
      phase,
      driverState,
      peerRegistered,
      closeRequired,
      closePending,
      driverReturned,
      driverPhase,
      raiseRootState,
      raiseRootSource,
      raiseRootHasChild,
      driverRaised,
      terminalFailureCount,
      raisePhase,
      harnessPhase,
      lastAction,
      atc>>

driverVars ==
    <<driverState,
      peerRegistered,
      closeRequired,
      closePending,
      driverReturned,
      driverPhase,
      raiseRootState,
      raiseRootSource,
      raiseRootHasChild,
      driverRaised,
      terminalFailureCount,
      raisePhase>>

driverRaiseVars ==
    <<raiseRootState,
      raiseRootSource,
      raiseRootHasChild,
      driverRaised,
      terminalFailureCount,
      raisePhase>>

TypeOK ==
    /\ atc \in [stage : {"Idle", "Driving", "Requested", "Returned", "Delivered", "Used", "Cancelled"},
                  depth : 0..1, stabilizing : BOOLEAN, dirty : 0..1,
                  source : {"Immediate", "Dependency", "None"}, deadline : BOOLEAN,
                  child : BOOLEAN, childState : {"Vacant", "Pending", "Terminal"}, childDeadline : BOOLEAN,
                  root : {"Pending", "Terminal"}, gate : {"Pending", "Terminal"},
                  rootOutcome : {"None", "Succeeded", "Cancelled"}, gateOutcome : {"None", "Succeeded", "Failed"},
                  deferral : 0..2, requested : BOOLEAN, delivered : BOOLEAN, waitFailed : BOOLEAN,
                  action : {"Init", "ATCDrive", "ATCProtectedReturn", "ATCDriverReturn",
                            "ATCStableDeliver", "ATCBrokenDeliver", "ATCUse", "ATCCancel"}]
    /\ targetState \in {"Pending", "Terminal", "Idle"}
    /\ targetReported \in BOOLEAN
    /\ otherState \in {"Pending", "Terminal", "Idle"}
    /\ otherReported \in BOOLEAN
    /\ savedOtherReported \in BOOLEAN
    /\ cancellationRequested \in BOOLEAN
    /\ phase \in {"Ready", "Drain", "Restore", "Poll", "Done"}
    /\ driverState \in {"Pending", "Terminal", "Idle"}
    /\ peerRegistered \in BOOLEAN
    /\ closeRequired \in BOOLEAN
    /\ closePending \in BOOLEAN
    /\ driverReturned \in BOOLEAN
    /\ driverPhase \in
         {"Ready",
          "Blocked",
          "Returned",
          "PeerDrained",
          "CleanupRequested",
          "CleanupBlocked",
          "DispatchPending",
          "DispatchAborted",
          "HandoffPublished",
          "HandoffAborted",
          "Done"}
    /\ raiseRootState \in {"Pending", "Terminal"}
    /\ raiseRootSource \in {"Immediate", "None"}
    /\ raiseRootHasChild \in BOOLEAN
    /\ driverRaised \in BOOLEAN
    /\ terminalFailureCount \in 0..1
    /\ raisePhase \in {"Ready", "Raised", "Done"}
    /\ harnessPhase \in {"Ready", "Finalized", "Finished", "Consumed", "Disposed", "Done"}
    /\ lastAction \in
         {"Init",
          "BeginFinalize",
          "EarlyGateReturn",
          "RestoreReported",
          "WaitForTarget",
          "DispatchTarget",
          "FinishFinalize",
          "Finalize",
          "FailUpgradeDriver",
          "DrainPeer",
          "FinishFailedUpgrade",
          "ConsumeFailedUpgrade",
          "FinalizeFailedUpgrade",
          "CompleteCleanupDispatch",
          "AbortCleanupDispatch",
          "CompleteCleanupHandoff",
          "AbortCleanupHandoff",
          "DriverRaises",
          "DriverFinish",
          "DriverConsume",
          "DriverFinalize"}

\* Owner-local live-set ATC extension. Legacy workflows remain unchanged.
legacyVars ==
    <<targetState, targetReported, otherState, otherReported, savedOtherReported,
      cancellationRequested, phase, driverState, peerRegistered, closeRequired,
      closePending, driverReturned, driverPhase, raiseRootState, raiseRootSource,
      raiseRootHasChild, driverRaised, terminalFailureCount, raisePhase,
      harnessPhase, lastAction>>

ATCInitial ==
    [stage |-> "Idle", depth |-> 0, stabilizing |-> FALSE, dirty |-> 0,
     source |-> IF ATCKind = "Batch" THEN "Immediate" ELSE "Dependency",
     deadline |-> FALSE, child |-> (ATCKind = "Stabilizer"),
     childState |-> IF ATCKind = "Stabilizer" THEN "Pending" ELSE "Vacant",
     childDeadline |-> (ATCKind = "Stabilizer"),
     root |-> "Pending", gate |-> "Pending", rootOutcome |-> "None", gateOutcome |-> "None", deferral |-> 0,
     requested |-> FALSE, delivered |-> FALSE, waitFailed |-> FALSE, action |-> "Init"]

\* At the owner-stack driver boundary, the immediate source is cleared, or
\* the terminal child is consumed and released. The batch/stabilizer guard is
\* live. The stabilizer witness completes its child outside a wait batch.
ATCDrive ==
    /\ atc.stage = "Idle"
    /\ atc' = [atc EXCEPT !.stage = "Driving",
                         !.depth = IF ATCKind = "Batch" THEN 1 ELSE 0,
                         !.stabilizing = (ATCKind = "Stabilizer"),
                         !.source = "None", !.deadline = FALSE,
                         !.child = FALSE, !.childState = "Vacant", !.childDeadline = FALSE,
                         !.deferral = IF ATCMode = "Deferred" THEN 1 ELSE 0,
                         !.action = "ATCDrive"]

\* The protected entry completes a queued ATC. Its wrapper briefly adds one
\* more deferral level, then returns to the driver at the previous level.
ATCProtectedReturn ==
    /\ atc.stage = "Driving"
    /\ atc' = [atc EXCEPT !.stage = "Requested", !.requested = TRUE,
                         !.action = "ATCProtectedReturn"]

ATCDriverReturn ==
    /\ atc.stage = "Requested"
    /\ atc.deferral > 0
    /\ atc' = [atc EXCEPT !.stage = "Returned",
                         !.root = IF ATCReturn = "Terminal" THEN "Terminal" ELSE "Pending",
                         !.rootOutcome = IF ATCReturn = "Terminal" THEN "Succeeded" ELSE "None",
                         !.source = IF ATCReturn = "Rearm" THEN "Immediate" ELSE "None",
                         !.dirty = IF ATCReturn = "Terminal" THEN 1 ELSE 0,
                         !.action = "ATCDriverReturn"]

\* The owner completes dependent propagation, restores both guards, then
\* releases the final deferral. ATC is delivered at that release boundary.
ATCStableDeliver ==
    /\ atc.stage = "Returned"
    /\ atc' = [atc EXCEPT !.stage = "Delivered", !.depth = 0, !.stabilizing = FALSE,
                         !.deferral = 0, !.requested = FALSE, !.delivered = TRUE, !.dirty = 0,
                         !.gate = IF atc.root = "Terminal" THEN "Terminal" ELSE "Pending",
                         !.gateOutcome = IF atc.root = "Terminal" THEN "Succeeded" ELSE "None",
                         !.action = "ATCStableDeliver"]

\* Broken mode drops the protected wrapper's own deferral to zero and
\* delivers ATC before the driver or either guard can complete.
ATCBrokenDeliver ==
    /\ atc.stage = "Requested" /\ atc.deferral = 0
    /\ atc' = [atc EXCEPT !.stage = "Delivered", !.deferral = 0,
                         !.requested = FALSE, !.delivered = TRUE,
                         !.action = "ATCBrokenDeliver"]

ATCUse ==
    /\ atc.stage = "Delivered"
    /\ atc' = [atc EXCEPT !.stage = "Used",
                         !.waitFailed = (atc.root = "Pending" /\ atc.source = "None"
                                         /\ ~atc.deadline /\ ~atc.child),
                         !.root = IF atc.source = "Immediate" THEN "Terminal" ELSE @,
                         !.rootOutcome = IF atc.source = "Immediate" THEN "Succeeded" ELSE @,
                         !.source = IF atc.source = "Immediate" THEN "None" ELSE @,
                         !.gate = IF atc.source = "Immediate" THEN "Terminal" ELSE @,
                         !.gateOutcome = IF atc.source = "Immediate" THEN "Succeeded" ELSE @,
                         !.action = "ATCUse"]

ATCCancel ==
    /\ atc.stage = "Used"
    /\ atc' = [atc EXCEPT !.stage = "Cancelled", !.root = "Terminal",
                         !.rootOutcome = IF atc.root = "Pending" THEN "Cancelled" ELSE @,
                         !.source = "None",
                         !.dirty = IF atc.depth > 0 \/ atc.stabilizing THEN 1 ELSE 0,
                         !.gate = IF atc.depth = 0 /\ ~atc.stabilizing THEN "Terminal" ELSE @,
                         !.gateOutcome = IF atc.depth = 0 /\ ~atc.stabilizing
                                         THEN IF atc.root = "Pending" THEN "Failed" ELSE @ ELSE @,
                         !.action = "ATCCancel"]

ATCNext ==
    \/ ATCDrive \/ ATCProtectedReturn \/ ATCDriverReturn
    \/ ATCStableDeliver \/ ATCBrokenDeliver \/ ATCUse \/ ATCCancel


Init ==
    /\ targetState = "Pending"
    /\ targetReported = FALSE
    /\ otherState = "Terminal"
    /\ otherReported = InitialOtherReported
    /\ savedOtherReported = InitialOtherReported
    /\ cancellationRequested = FALSE
    /\ phase = "Ready"
    /\ driverState = "Pending"
    /\ peerRegistered = TRUE
    /\ closeRequired = FALSE
    /\ closePending = FALSE
    /\ driverReturned = FALSE
    /\ driverPhase = "Ready"
    /\ raiseRootState = "Pending"
    /\ raiseRootSource = "Immediate"
    /\ raiseRootHasChild = FALSE
    /\ driverRaised = FALSE
    /\ terminalFailureCount = 0
    /\ raisePhase = "Ready"
    /\ harnessPhase = "Ready"
    /\ lastAction = "Init"
    /\ atc = ATCInitial

BeginFinalize ==
    /\ phase = "Ready"
    /\ savedOtherReported' = otherReported
    /\ cancellationRequested' = TRUE
    /\ phase' = "Drain"
    /\ lastAction' = "BeginFinalize"
    /\ UNCHANGED
         <<targetState,
           targetReported,
           otherState,
           otherReported>>
    /\ UNCHANGED driverVars
    /\ UNCHANGED harnessPhase

EarlyGateReturn ==
    /\ phase = "Drain"
    /\ targetState = "Pending"
    /\ DrainMode = "UserGate"
    /\ otherState = "Terminal"
    /\ ~otherReported
    /\ otherReported' = TRUE
    /\ phase' = "Restore"
    /\ lastAction' = "EarlyGateReturn"
    /\ UNCHANGED
         <<targetState,
           targetReported,
           otherState,
           savedOtherReported,
           cancellationRequested>>
    /\ UNCHANGED driverVars
    /\ UNCHANGED harnessPhase

RestoreReported ==
    /\ phase = "Restore"
    /\ otherReported' = savedOtherReported
    /\ phase' = "Drain"
    /\ lastAction' = "RestoreReported"
    /\ UNCHANGED
         <<targetState,
           targetReported,
           otherState,
           savedOtherReported,
           cancellationRequested>>
    /\ UNCHANGED driverVars
    /\ UNCHANGED harnessPhase

UserGateCannotReturnEarly ==
    ~(otherState = "Terminal" /\ ~otherReported)

WaitForTarget ==
    /\ phase = "Drain"
    /\ targetState = "Pending"
    /\ (DrainMode = "TargetGate"
        \/ (DrainMode = "UserGate" /\ UserGateCannotReturnEarly))
    /\ phase' = "Poll"
    /\ lastAction' = "WaitForTarget"
    /\ UNCHANGED
         <<targetState,
           targetReported,
           otherState,
           otherReported,
           savedOtherReported,
           cancellationRequested>>
    /\ UNCHANGED driverVars
    /\ UNCHANGED harnessPhase

DispatchTarget ==
    /\ phase = "Poll"
    /\ targetState = "Pending"
    /\ targetState' = "Terminal"
    /\ targetReported' = FALSE
    /\ phase' = "Drain"
    /\ lastAction' = "DispatchTarget"
    /\ UNCHANGED
         <<otherState,
           otherReported,
           savedOtherReported,
           cancellationRequested>>
    /\ UNCHANGED driverVars
    /\ UNCHANGED harnessPhase

FinishFinalize ==
    /\ phase = "Drain"
    /\ targetState = "Terminal"
    /\ targetState' = "Idle"
    /\ targetReported' = FALSE
    /\ otherReported' = savedOtherReported
    /\ phase' = "Done"
    /\ lastAction' = "FinishFinalize"
    /\ UNCHANGED
         <<otherState,
           savedOtherReported,
           cancellationRequested>>
    /\ UNCHANGED driverVars
    /\ UNCHANGED harnessPhase

FailUpgradeDriver ==
    /\ driverPhase = "Ready"
    /\ driverState = "Pending"
    /\ peerRegistered
    /\ closeRequired' = TRUE
    /\ closePending' = FALSE
    /\ driverState' = IF DriverCloseMode = "Deferred" THEN "Terminal" ELSE "Pending"
    /\ driverReturned' = (DriverCloseMode = "Deferred")
    /\ driverPhase' = IF DriverCloseMode = "Deferred" THEN "Returned" ELSE "Blocked"
    /\ lastAction' = "FailUpgradeDriver"
    /\ UNCHANGED
         <<targetState,
           targetReported,
           otherState,
           otherReported,
           savedOtherReported,
           cancellationRequested,
           phase,
           peerRegistered,
           harnessPhase>>
    /\ UNCHANGED driverRaiseVars

DrainPeer ==
    /\ driverPhase \in {"Returned", "CleanupRequested"}
    /\ peerRegistered
    /\ peerRegistered' = FALSE
    /\ closePending' = FALSE
    /\ driverPhase' =
         IF driverPhase = "CleanupRequested" THEN "Done" ELSE "PeerDrained"
    /\ lastAction' = "DrainPeer"
    /\ UNCHANGED
         <<targetState,
           targetReported,
           otherState,
           otherReported,
           savedOtherReported,
           cancellationRequested,
           phase,
           driverState,
           closeRequired,
           driverReturned,
           harnessPhase>>
    /\ UNCHANGED driverRaiseVars

SplitCleanupHandoff ==
    /\ ~peerRegistered
    /\ CleanupCloseMode = "Deferred"
    /\ CleanupHandoffMode = "Split"

SplitCleanupDispatch ==
    /\ ~peerRegistered
    /\ CleanupCloseMode = "Deferred"
    /\ CleanupDispatchMode = "Split"

CleanupPhase ==
    IF SplitCleanupDispatch
    THEN "DispatchPending"
    ELSE IF peerRegistered
    THEN IF CleanupCloseMode = "Deferred" THEN "CleanupRequested" ELSE "CleanupBlocked"
    ELSE IF SplitCleanupHandoff THEN "HandoffPublished" ELSE "Done"

FinishFailedUpgrade ==
    /\ driverPhase \in {"Returned", "PeerDrained"}
    /\ driverState = "Terminal"
    /\ closeRequired
    /\ driverState' = "Idle"
    /\ closeRequired' = (SplitCleanupDispatch \/ SplitCleanupHandoff)
    /\ closePending' =
         (~SplitCleanupDispatch
          /\ (SplitCleanupHandoff \/ (peerRegistered /\ CleanupCloseMode = "Deferred")))
    /\ driverPhase' = CleanupPhase
    /\ lastAction' = "FinishFailedUpgrade"
    /\ UNCHANGED
         <<targetState,
           targetReported,
           otherState,
           otherReported,
           savedOtherReported,
           cancellationRequested,
           phase,
           peerRegistered,
           driverReturned,
           harnessPhase>>
    /\ UNCHANGED driverRaiseVars

ConsumeFailedUpgrade ==
    /\ driverPhase \in {"Returned", "PeerDrained"}
    /\ driverState = "Terminal"
    /\ closeRequired
    /\ driverState' = "Idle"
    /\ closeRequired' = (SplitCleanupDispatch \/ SplitCleanupHandoff)
    /\ closePending' =
         (~SplitCleanupDispatch
          /\ (SplitCleanupHandoff \/ (peerRegistered /\ CleanupCloseMode = "Deferred")))
    /\ driverPhase' = CleanupPhase
    /\ lastAction' = "ConsumeFailedUpgrade"
    /\ UNCHANGED
         <<targetState,
           targetReported,
           otherState,
           otherReported,
           savedOtherReported,
           cancellationRequested,
           phase,
           peerRegistered,
           driverReturned,
           harnessPhase>>
    /\ UNCHANGED driverRaiseVars

FinalizeFailedUpgrade ==
    /\ driverPhase \in {"Returned", "PeerDrained"}
    /\ driverState = "Terminal"
    /\ closeRequired
    /\ driverState' = "Idle"
    /\ closeRequired' = (SplitCleanupDispatch \/ SplitCleanupHandoff)
    /\ closePending' =
         (~SplitCleanupDispatch
          /\ (SplitCleanupHandoff \/ (peerRegistered /\ CleanupCloseMode = "Deferred")))
    /\ driverPhase' = CleanupPhase
    /\ lastAction' = "FinalizeFailedUpgrade"
    /\ UNCHANGED
         <<targetState,
           targetReported,
           otherState,
           otherReported,
           savedOtherReported,
           cancellationRequested,
           phase,
           peerRegistered,
           driverReturned,
           harnessPhase>>
    /\ UNCHANGED driverRaiseVars

CompleteCleanupDispatch ==
    /\ driverPhase = "DispatchPending"
    /\ driverState = "Idle"
    /\ ~peerRegistered
    /\ closeRequired
    /\ ~closePending
    /\ closeRequired' = (CleanupHandoffMode = "Split")
    /\ closePending' = (CleanupHandoffMode = "Split")
    /\ driverPhase' =
         IF CleanupHandoffMode = "Split" THEN "HandoffPublished" ELSE "Done"
    /\ lastAction' = "CompleteCleanupDispatch"
    /\ UNCHANGED
         <<targetState,
           targetReported,
           otherState,
           otherReported,
           savedOtherReported,
           cancellationRequested,
           phase,
           driverState,
           peerRegistered,
           driverReturned,
           harnessPhase>>
    /\ UNCHANGED driverRaiseVars

AbortCleanupDispatch ==
    /\ driverPhase = "DispatchPending"
    /\ driverState = "Idle"
    /\ ~peerRegistered
    /\ closeRequired
    /\ ~closePending
    /\ driverPhase' = "DispatchAborted"
    /\ lastAction' = "AbortCleanupDispatch"
    /\ UNCHANGED
         <<targetState,
           targetReported,
           otherState,
           otherReported,
           savedOtherReported,
           cancellationRequested,
           phase,
           driverState,
           peerRegistered,
           closeRequired,
           closePending,
           driverReturned,
           harnessPhase>>
    /\ UNCHANGED driverRaiseVars

CompleteCleanupHandoff ==
    /\ driverPhase = "HandoffPublished"
    /\ driverState = "Idle"
    /\ ~peerRegistered
    /\ closeRequired
    /\ closePending
    /\ closeRequired' = FALSE
    /\ closePending' = FALSE
    /\ driverPhase' = "Done"
    /\ lastAction' = "CompleteCleanupHandoff"
    /\ UNCHANGED
         <<targetState,
           targetReported,
           otherState,
           otherReported,
           savedOtherReported,
           cancellationRequested,
           phase,
           driverState,
           peerRegistered,
           driverReturned,
           harnessPhase>>
    /\ UNCHANGED driverRaiseVars

AbortCleanupHandoff ==
    /\ driverPhase = "HandoffPublished"
    /\ driverState = "Idle"
    /\ ~peerRegistered
    /\ closeRequired
    /\ closePending
    /\ driverPhase' = "HandoffAborted"
    /\ lastAction' = "AbortCleanupHandoff"
    /\ UNCHANGED
         <<targetState,
           targetReported,
           otherState,
           otherReported,
           savedOtherReported,
           cancellationRequested,
           phase,
           driverState,
           peerRegistered,
           closeRequired,
           closePending,
           driverReturned,
           harnessPhase>>
    /\ UNCHANGED driverRaiseVars

DriverRaiseEffect ==
    /\ raisePhase = "Ready"
    /\ raiseRootState = "Pending"
    /\ raiseRootSource = "Immediate"
    /\ ~raiseRootHasChild
    /\ raiseRootState' = IF DriverRaiseMode = "Terminalize" THEN "Terminal" ELSE "Pending"
    /\ raiseRootSource' = "None"
    /\ raiseRootHasChild' = FALSE
    /\ driverRaised' = TRUE
    /\ terminalFailureCount' = IF DriverRaiseMode = "Terminalize" THEN 1 ELSE 0
    /\ raisePhase' = IF DriverRaiseMode = "Terminalize" THEN "Done" ELSE "Raised"
    /\ lastAction' = "DriverRaises"

DriverRaises ==
    /\ DriverRaiseEffect
    /\ UNCHANGED
         <<targetState,
           targetReported,
           otherState,
           otherReported,
           savedOtherReported,
           cancellationRequested,
           phase,
           driverState,
           peerRegistered,
           closeRequired,
           closePending,
           driverReturned,
           driverPhase,
           harnessPhase>>

LegacyNext ==
    \/ BeginFinalize
    \/ EarlyGateReturn
    \/ RestoreReported
    \/ WaitForTarget
    \/ DispatchTarget
    \/ FinishFinalize
    \/ FailUpgradeDriver
    \/ DrainPeer
    \/ FinishFailedUpgrade
    \/ ConsumeFailedUpgrade
    \/ FinalizeFailedUpgrade
    \/ CompleteCleanupDispatch
    \/ AbortCleanupDispatch
    \/ CompleteCleanupHandoff
    \/ AbortCleanupHandoff
    \/ DriverRaises

Fairness ==
    /\ WF_legacyVars(BeginFinalize)
    /\ WF_legacyVars(EarlyGateReturn)
    /\ WF_legacyVars(RestoreReported)
    /\ WF_legacyVars(WaitForTarget)
    /\ WF_legacyVars(DispatchTarget)
    /\ WF_legacyVars(FinishFinalize)
    /\ WF_legacyVars(FailUpgradeDriver)
    /\ WF_legacyVars(DrainPeer)
    /\ WF_legacyVars(FinishFailedUpgrade)
    /\ WF_legacyVars(ConsumeFailedUpgrade)
    /\ WF_legacyVars(FinalizeFailedUpgrade)
    /\ WF_legacyVars(CompleteCleanupDispatch)
    /\ WF_legacyVars(AbortCleanupDispatch)
    /\ WF_legacyVars(CompleteCleanupHandoff)
    /\ WF_legacyVars(AbortCleanupHandoff)
    /\ WF_legacyVars(DriverRaises)

Next == (LegacyNext /\ UNCHANGED atc)
        \/ (ATCMode /= "Disabled" /\ ATCNext /\ UNCHANGED legacyVars)

Spec == Init /\ [][Next]_vars /\ Fairness

ReportedOnlyTerminal ==
    /\ (targetReported => targetState = "Terminal")
    /\ (otherReported => otherState = "Terminal")

FinalStateReleased ==
    phase = "Done" => targetState = "Idle"

OtherReportRestored ==
    phase = "Done" => otherReported = savedOtherReported

DriverReturnIsTerminal ==
    driverPhase \in {"Returned", "PeerDrained"} =>
        /\ driverState = "Terminal"
        /\ closeRequired
        /\ ~closePending
        /\ driverReturned

DriverDisposeBeforePeerReturns ==
    driverPhase = "CleanupRequested" =>
        /\ driverState = "Idle"
        /\ peerRegistered
        /\ ~closeRequired
        /\ closePending
        /\ driverReturned

DriverDispatchStateRetainsObligation ==
    driverPhase \in {"DispatchPending", "DispatchAborted"} =>
        /\ driverState = "Idle"
        /\ ~peerRegistered
        /\ closeRequired
        /\ ~closePending
        /\ driverReturned

DriverHandoffStateIsOwned ==
    driverPhase \in {"HandoffPublished", "HandoffAborted"} =>
        /\ driverState = "Idle"
        /\ ~peerRegistered
        /\ closeRequired
        /\ closePending
        /\ driverReturned

DriverCleanupIsOrdered ==
    driverPhase = "Done" =>
        /\ driverState = "Idle"
        /\ ~peerRegistered
        /\ ~closeRequired
        /\ ~closePending
        /\ driverReturned

DriverRaiseHasProgress ==
    driverRaised =>
        \/ raiseRootState = "Terminal"
        \/ raiseRootSource /= "None"
        \/ raiseRootHasChild

DriverRaiseTerminalExactlyOnce ==
    /\ (terminalFailureCount = 1) = (raiseRootState = "Terminal")
    /\ (raisePhase = "Done" =>
           /\ driverRaised
           /\ raiseRootState = "Terminal"
           /\ raiseRootSource = "None"
           /\ ~raiseRootHasChild
           /\ terminalFailureCount = 1)

FinalizeCompletes == <>(phase = "Done")

DriverFailureCompletes == <>(driverPhase = "Done")

DisposeBeforePeerCompletes == []((driverPhase = "CleanupRequested") => <>(driverPhase = "Done"))

PeerBeforeDisposeCompletes == []((driverPhase = "PeerDrained") => <>(driverPhase = "Done"))

DriverRaiseCompletes == <>(raisePhase = "Done")

\* The conformance trace treats finalization as one public transition while
\* the detailed Spec above checks its internal wait/restore/poll protocol.
FinalizeAtomically ==
    /\ phase = "Ready"
    /\ targetState' = "Idle"
    /\ targetReported' = FALSE
    /\ otherState' = otherState
    /\ otherReported' = otherReported
    /\ savedOtherReported' = otherReported
    /\ cancellationRequested' = TRUE
    /\ phase' = "Done"
    /\ harnessPhase' = "Finalized"
    /\ lastAction' = "Finalize"
    /\ UNCHANGED
         <<driverState,
           peerRegistered,
           closeRequired,
           closePending,
           driverReturned,
           driverPhase>>
    /\ UNCHANGED driverRaiseVars

DriverFinishAtomically ==
    /\ phase = "Done"
    /\ driverPhase = "Ready"
    /\ harnessPhase = "Finalized"
    /\ driverState' = "Idle"
    /\ peerRegistered' = FALSE
    /\ closeRequired' = FALSE
    /\ closePending' = FALSE
    /\ driverReturned' = TRUE
    /\ driverPhase' = "Done"
    /\ harnessPhase' = "Finished"
    /\ lastAction' = "DriverFinish"
    /\ UNCHANGED
         <<targetState,
           targetReported,
           otherState,
           otherReported,
           savedOtherReported,
           cancellationRequested,
           phase>>
    /\ UNCHANGED driverRaiseVars

DriverConsumeAtomically ==
    /\ phase = "Done"
    /\ harnessPhase = "Finished"
    /\ driverState' = "Idle"
    /\ peerRegistered' = FALSE
    /\ closeRequired' = FALSE
    /\ closePending' = FALSE
    /\ driverReturned' = TRUE
    /\ driverPhase' = "Done"
    /\ harnessPhase' = "Consumed"
    /\ lastAction' = "DriverConsume"
    /\ UNCHANGED
         <<targetState,
           targetReported,
           otherState,
           otherReported,
           savedOtherReported,
           cancellationRequested,
           phase>>
    /\ UNCHANGED driverRaiseVars

DriverFinalizeAtomically ==
    /\ phase = "Done"
    /\ harnessPhase = "Consumed"
    /\ driverState' = "Idle"
    /\ peerRegistered' = FALSE
    /\ closeRequired' = FALSE
    /\ closePending' = FALSE
    /\ driverReturned' = TRUE
    /\ driverPhase' = "Done"
    /\ harnessPhase' = "Disposed"
    /\ lastAction' = "DriverFinalize"
    /\ UNCHANGED
         <<targetState,
           targetReported,
           otherState,
           otherReported,
           savedOtherReported,
           cancellationRequested,
           phase>>
    /\ UNCHANGED driverRaiseVars

DriverRaisesAtomically ==
    /\ harnessPhase = "Disposed"
    /\ DriverRaiseEffect
    /\ harnessPhase' = "Done"
    /\ UNCHANGED
         <<targetState,
           targetReported,
           otherState,
           otherReported,
           savedOtherReported,
           cancellationRequested,
           phase,
           driverState,
           peerRegistered,
           closeRequired,
           closePending,
           driverReturned,
           driverPhase>>

LegacyHarnessNext ==
    \/ FinalizeAtomically
    \/ DriverFinishAtomically
    \/ DriverConsumeAtomically
    \/ DriverFinalizeAtomically
    \/ DriverRaisesAtomically

HarnessNext == LegacyHarnessNext /\ UNCHANGED atc

HarnessSpec == Init /\ [][HarnessNext]_vars

HarnessInputType ==
    [event : {"Finalize", "DriverFinish", "DriverConsume", "DriverFinalize", "DriverRaises"}]

HarnessOutcomeType ==
    [returned : BOOLEAN,
     otherReplayable : BOOLEAN,
     peerDrainable : BOOLEAN,
     closeDeferred : BOOLEAN,
     cleanupBeforePeer : BOOLEAN,
     closedAtFinish : BOOLEAN,
     closedAtConsume : BOOLEAN,
     closedAtFinalize : BOOLEAN,
     failureRetained : BOOLEAN,
     resultDiscarded : BOOLEAN,
     driverRaiseCaught : BOOLEAN,
     oneTerminalFailure : BOOLEAN,
     raiseSourceCleared : BOOLEAN,
     raiseChildCleared : BOOLEAN]

WitnessIncomplete == harnessPhase /= "Done"

Alias == [
    action |-> lastAction,
    role |->
        CASE lastAction = "DriverFinish" -> "driver-finish"
          [] lastAction = "DriverConsume" -> "driver-consume"
          [] lastAction = "DriverFinalize" -> "driver-finalize"
          [] lastAction = "DriverRaises" -> "driver-raise"
          [] OTHER -> "finalize",
    input |-> [event |-> lastAction],
    outcome |-> [
        returned |->
            IF lastAction \in {"DriverFinish", "DriverConsume", "DriverFinalize"}
            THEN driverReturned
            ELSE phase = "Done",
        otherReplayable |->
            lastAction = "Finalize" /\ phase = "Done"
                /\ otherState = "Terminal" /\ ~otherReported,
        peerDrainable |->
            lastAction \in {"DriverFinish", "DriverConsume", "DriverFinalize"}
                /\ driverPhase = "Done" /\ ~peerRegistered,
        closeDeferred |->
            lastAction \in {"DriverFinish", "DriverConsume", "DriverFinalize"}
                /\ driverReturned,
        cleanupBeforePeer |->
            lastAction \in {"DriverFinish", "DriverConsume", "DriverFinalize"},
        closedAtFinish |->
            lastAction = "DriverFinish" /\ driverPhase = "Done" /\ ~closeRequired,
        closedAtConsume |->
            lastAction = "DriverConsume" /\ driverPhase = "Done" /\ ~closeRequired,
        closedAtFinalize |->
            lastAction = "DriverFinalize" /\ driverPhase = "Done" /\ ~closeRequired,
        failureRetained |->
            (lastAction = "DriverFinish" /\ driverPhase = "Done")
            \/ (lastAction = "DriverRaises" /\ terminalFailureCount = 1),
        resultDiscarded |->
            lastAction \in {"DriverConsume", "DriverFinalize"} /\ driverPhase = "Done",
        driverRaiseCaught |-> lastAction = "DriverRaises" /\ raisePhase = "Done",
        oneTerminalFailure |->
            lastAction = "DriverRaises" /\ terminalFailureCount = 1,
        raiseSourceCleared |->
            lastAction = "DriverRaises" /\ raiseRootSource = "None",
        raiseChildCleared |->
            lastAction = "DriverRaises" /\ ~raiseRootHasChild
    ],
    state |-> [
        targetState |-> targetState,
        targetReported |-> targetReported,
        otherState |-> otherState,
        otherReported |-> otherReported,
        savedOtherReported |-> savedOtherReported,
        cancellationRequested |-> cancellationRequested,
        phase |-> phase,
        driverState |-> driverState,
        peerRegistered |-> peerRegistered,
        closeRequired |-> closeRequired,
        closePending |-> closePending,
        driverReturned |-> driverReturned,
        driverPhase |-> driverPhase,
        raiseRootState |-> raiseRootState,
        raiseRootSource |-> raiseRootSource,
        raiseRootHasChild |-> raiseRootHasChild,
        driverRaised |-> driverRaised,
        terminalFailureCount |-> terminalFailureCount,
        raisePhase |-> raisePhase,
        harnessPhase |-> harnessPhase,
        lastAction |-> lastAction,
        atc |-> atc
    ],
    model_source |-> lastAction
]


ATCSpec == Init /\ [][ATCNext /\ UNCHANGED legacyVars]_vars
           /\ WF_vars(ATCNext /\ UNCHANGED legacyVars)

ATCResumeConsistent ==
    atc.delivered =>
        /\ atc.depth = 0 /\ ~atc.stabilizing /\ atc.deferral = 0
        /\ (atc.root = "Terminal" \/ atc.source /= "None" \/ atc.deadline \/ atc.child)

ATCPropagationGuardLeak == atc.delivered => atc.depth = 0
ATCStabilizerGuardLeak == atc.delivered => ~atc.stabilizing
ATCRequestRetained == atc.stage = "Requested" => atc.requested /\ ~atc.delivered
ATCUseHasProgress == atc.stage \in {"Used", "Cancelled"} => ~atc.waitFailed
ATCCancellationPropagates == atc.stage = "Cancelled" => atc.gate = "Terminal" /\ atc.dirty = 0
ATCCompletes == <> (atc.stage = "Cancelled")
ATCWitnessIncomplete == atc.stage /= "Cancelled"

ATCInputType ==
    [event : {"ATCDrive", "ATCProtectedReturn", "ATCDriverReturn", "ATCStableDeliver",
              "ATCBrokenDeliver", "ATCUse", "ATCCancel"}]
ATCOutcomeType == [delivered : BOOLEAN, waitFailed : BOOLEAN]
ATCAlias ==
    [action |-> atc.action, role |-> "owner",
     input |-> [event |-> atc.action],
     outcome |-> [delivered |-> atc.delivered, waitFailed |-> atc.waitFailed],
     state |-> atc,
     model_source |-> atc.action]



=============================================================================
