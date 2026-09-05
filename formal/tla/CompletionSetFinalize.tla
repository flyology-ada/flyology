----------------------- MODULE CompletionSetFinalize -----------------------
EXTENDS Naturals

CONSTANTS DrainMode, DriverCloseMode, InitialOtherReported

ASSUME DrainMode \in {"UserGate", "TargetGate"}
ASSUME DriverCloseMode \in {"Blocking", "Deferred"}
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
          driverReturned,
          driverPhase,
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
      driverReturned,
      driverPhase,
      lastAction>>

driverVars ==
    <<driverState, peerRegistered, closeRequired, driverReturned, driverPhase>>

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
    /\ driverReturned \in BOOLEAN
    /\ driverPhase \in {"Ready", "Blocked", "Returned", "PeerDrained", "Done"}
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
          "DriverFailure"}

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
    /\ driverReturned = FALSE
    /\ driverPhase = "Ready"
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

FailUpgradeDriver ==
    /\ driverPhase = "Ready"
    /\ driverState = "Pending"
    /\ peerRegistered
    /\ closeRequired' = TRUE
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
           peerRegistered>>

DrainPeer ==
    /\ driverPhase = "Returned"
    /\ peerRegistered
    /\ peerRegistered' = FALSE
    /\ driverPhase' = "PeerDrained"
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
           driverReturned>>

FinishFailedUpgrade ==
    /\ driverPhase = "PeerDrained"
    /\ driverState = "Terminal"
    /\ ~peerRegistered
    /\ closeRequired
    /\ driverState' = "Idle"
    /\ closeRequired' = FALSE
    /\ driverPhase' = "Done"
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
           driverReturned>>

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
        /\ driverReturned

DriverCleanupIsOrdered ==
    driverPhase = "Done" =>
        /\ driverState = "Idle"
        /\ ~peerRegistered
        /\ ~closeRequired
        /\ driverReturned

FinalizeCompletes == <>(phase = "Done")

DriverFailureCompletes == <>(driverPhase = "Done")

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
    /\ lastAction' = "Finalize"
    /\ UNCHANGED
         <<driverState,
           peerRegistered,
           closeRequired,
           driverReturned,
           driverPhase>>

DriverFailureAtomically ==
    /\ phase = "Done"
    /\ driverPhase = "Ready"
    /\ driverState' = "Idle"
    /\ peerRegistered' = FALSE
    /\ closeRequired' = FALSE
    /\ driverReturned' = TRUE
    /\ driverPhase' = "Done"
    /\ lastAction' = "DriverFailure"
    /\ UNCHANGED
         <<targetState,
           targetReported,
           otherState,
           otherReported,
           savedOtherReported,
           cancellationRequested,
           phase>>

HarnessNext == FinalizeAtomically \/ DriverFailureAtomically

HarnessSpec == Init /\ [][HarnessNext]_vars

HarnessInputType == [event : {"Finalize", "DriverFailure"}]

HarnessOutcomeType ==
    [returned : BOOLEAN,
     otherReplayable : BOOLEAN,
     peerDrainable : BOOLEAN,
     closeDeferred : BOOLEAN,
     closedAtFinish : BOOLEAN,
     failureRetained : BOOLEAN]

WitnessIncomplete == driverPhase /= "Done"

Alias == [
    action |-> lastAction,
    role |-> IF lastAction = "DriverFailure" THEN "driver-close" ELSE "finalize",
    input |-> [event |-> lastAction],
    outcome |-> [
        returned |->
            IF lastAction = "DriverFailure" THEN driverPhase = "Done" ELSE phase = "Done",
        otherReplayable |->
            lastAction = "Finalize" /\ phase = "Done"
                /\ otherState = "Terminal" /\ ~otherReported,
        peerDrainable |->
            lastAction = "DriverFailure" /\ driverPhase = "Done" /\ ~peerRegistered,
        closeDeferred |-> lastAction = "DriverFailure" /\ driverReturned,
        closedAtFinish |->
            lastAction = "DriverFailure" /\ driverPhase = "Done" /\ ~closeRequired,
        failureRetained |-> lastAction = "DriverFailure" /\ driverPhase = "Done"
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
        driverReturned |-> driverReturned,
        driverPhase |-> driverPhase,
        lastAction |-> lastAction
    ],
    model_source |-> lastAction
]

=============================================================================
