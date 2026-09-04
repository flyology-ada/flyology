----------------------- MODULE CompletionSetFinalize -----------------------
EXTENDS Naturals

CONSTANTS DrainMode, InitialOtherReported

ASSUME DrainMode \in {"UserGate", "TargetGate"}
ASSUME InitialOtherReported \in BOOLEAN

VARIABLES targetState,
          targetReported,
          otherState,
          otherReported,
          savedOtherReported,
          cancellationRequested,
          phase,
          lastAction

vars ==
    <<targetState,
      targetReported,
      otherState,
      otherReported,
      savedOtherReported,
      cancellationRequested,
      phase,
      lastAction>>

TypeOK ==
    /\ targetState \in {"Pending", "Terminal", "Idle"}
    /\ targetReported \in BOOLEAN
    /\ otherState \in {"Pending", "Terminal", "Idle"}
    /\ otherReported \in BOOLEAN
    /\ savedOtherReported \in BOOLEAN
    /\ cancellationRequested \in BOOLEAN
    /\ phase \in {"Ready", "Drain", "Restore", "Poll", "Done"}
    /\ lastAction \in
         {"Init",
          "BeginFinalize",
          "EarlyGateReturn",
          "RestoreReported",
          "WaitForTarget",
          "DispatchTarget",
          "FinishFinalize",
          "Finalize"}

Init ==
    /\ targetState = "Pending"
    /\ targetReported = FALSE
    /\ otherState = "Terminal"
    /\ otherReported = InitialOtherReported
    /\ savedOtherReported = InitialOtherReported
    /\ cancellationRequested = FALSE
    /\ phase = "Ready"
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

Next ==
    \/ BeginFinalize
    \/ EarlyGateReturn
    \/ RestoreReported
    \/ WaitForTarget
    \/ DispatchTarget
    \/ FinishFinalize

Fairness ==
    /\ WF_vars(BeginFinalize)
    /\ WF_vars(EarlyGateReturn)
    /\ WF_vars(RestoreReported)
    /\ WF_vars(WaitForTarget)
    /\ WF_vars(DispatchTarget)
    /\ WF_vars(FinishFinalize)

Spec == Init /\ [][Next]_vars /\ Fairness

ReportedOnlyTerminal ==
    /\ (targetReported => targetState = "Terminal")
    /\ (otherReported => otherState = "Terminal")

FinalStateReleased ==
    phase = "Done" => targetState = "Idle"

OtherReportRestored ==
    phase = "Done" => otherReported = savedOtherReported

FinalizeCompletes == <>(phase = "Done")

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

HarnessNext == FinalizeAtomically

HarnessSpec == Init /\ [][HarnessNext]_vars

HarnessInputType == [event : {"Finalize"}]

HarnessOutcomeType == [returned : BOOLEAN, otherReplayable : BOOLEAN]

WitnessIncomplete == phase /= "Done"

Alias == [
    action |-> lastAction,
    role |-> "finalize",
    input |-> [event |-> lastAction],
    outcome |-> [
        returned |-> phase = "Done",
        otherReplayable |->
            phase = "Done" /\ otherState = "Terminal" /\ ~otherReported
    ],
    state |-> [
        targetState |-> targetState,
        targetReported |-> targetReported,
        otherState |-> otherState,
        otherReported |-> otherReported,
        savedOtherReported |-> savedOtherReported,
        cancellationRequested |-> cancellationRequested,
        phase |-> phase,
        lastAction |-> lastAction
    ],
    model_source |-> lastAction
]

=============================================================================
