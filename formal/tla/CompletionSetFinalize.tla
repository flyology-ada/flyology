----------------------- MODULE CompletionSetFinalize -----------------------
EXTENDS Naturals

CONSTANTS DrainMode,
          DriverCloseMode,
          CleanupCloseMode,
          CleanupDispatchMode,
          CleanupHandoffMode,
          InitialOtherReported

ASSUME DrainMode \in {"UserGate", "TargetGate"}
ASSUME DriverCloseMode \in {"Blocking", "Deferred"}
ASSUME CleanupCloseMode \in {"Blocking", "Deferred"}
ASSUME CleanupDispatchMode \in {"Atomic", "Split"}
ASSUME CleanupHandoffMode \in {"Atomic", "Split"}
ASSUME InitialOtherReported \in BOOLEAN

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
          harnessPhase,
          lastAction

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
      harnessPhase,
      lastAction>>

driverVars ==
    <<driverState, peerRegistered, closeRequired, closePending, driverReturned, driverPhase>>

TypeOK ==
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
    /\ harnessPhase \in {"Ready", "Finalized", "Finished", "Consumed", "Done"}
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
          "DriverFinish",
          "DriverConsume",
          "DriverFinalize"}

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
    /\ harnessPhase = "Ready"
    /\ lastAction = "Init"

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

Next ==
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

Fairness ==
    /\ WF_vars(BeginFinalize)
    /\ WF_vars(EarlyGateReturn)
    /\ WF_vars(RestoreReported)
    /\ WF_vars(WaitForTarget)
    /\ WF_vars(DispatchTarget)
    /\ WF_vars(FinishFinalize)
    /\ WF_vars(FailUpgradeDriver)
    /\ WF_vars(DrainPeer)
    /\ WF_vars(FinishFailedUpgrade)
    /\ WF_vars(ConsumeFailedUpgrade)
    /\ WF_vars(FinalizeFailedUpgrade)
    /\ WF_vars(CompleteCleanupDispatch)
    /\ WF_vars(AbortCleanupDispatch)
    /\ WF_vars(CompleteCleanupHandoff)
    /\ WF_vars(AbortCleanupHandoff)

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

FinalizeCompletes == <>(phase = "Done")

DriverFailureCompletes == <>(driverPhase = "Done")

DisposeBeforePeerCompletes == []((driverPhase = "CleanupRequested") => <>(driverPhase = "Done"))

PeerBeforeDisposeCompletes == []((driverPhase = "PeerDrained") => <>(driverPhase = "Done"))

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

DriverFinalizeAtomically ==
    /\ phase = "Done"
    /\ harnessPhase = "Consumed"
    /\ driverState' = "Idle"
    /\ peerRegistered' = FALSE
    /\ closeRequired' = FALSE
    /\ closePending' = FALSE
    /\ driverReturned' = TRUE
    /\ driverPhase' = "Done"
    /\ harnessPhase' = "Done"
    /\ lastAction' = "DriverFinalize"
    /\ UNCHANGED
         <<targetState,
           targetReported,
           otherState,
           otherReported,
           savedOtherReported,
           cancellationRequested,
           phase>>

HarnessNext ==
    \/ FinalizeAtomically
    \/ DriverFinishAtomically
    \/ DriverConsumeAtomically
    \/ DriverFinalizeAtomically

HarnessSpec == Init /\ [][HarnessNext]_vars

HarnessInputType == [event : {"Finalize", "DriverFinish", "DriverConsume", "DriverFinalize"}]

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
     resultDiscarded : BOOLEAN]

WitnessIncomplete == harnessPhase /= "Done"

Alias == [
    action |-> lastAction,
    role |->
        CASE lastAction = "DriverFinish" -> "driver-finish"
          [] lastAction = "DriverConsume" -> "driver-consume"
          [] lastAction = "DriverFinalize" -> "driver-finalize"
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
        failureRetained |-> lastAction = "DriverFinish" /\ driverPhase = "Done",
        resultDiscarded |->
            lastAction \in {"DriverConsume", "DriverFinalize"} /\ driverPhase = "Done"
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
        harnessPhase |-> harnessPhase,
        lastAction |-> lastAction
    ],
    model_source |-> lastAction
]

=============================================================================
