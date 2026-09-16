--------------------- MODULE CompletionSetFinalizeProof ---------------------
EXTENDS CompletionSetFinalize

\* The original proof concerns legacy finalization state. The expanded
\* TypeOK, including ATC state, is checked by finite model configurations.
LegacyInit ==
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

LegacyTypeOK ==
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
         {"Ready", "Blocked", "Returned", "PeerDrained", "CleanupRequested",
          "CleanupBlocked", "DispatchPending", "DispatchAborted",
          "HandoffPublished", "HandoffAborted", "Done"}
    /\ raiseRootState \in {"Pending", "Terminal"}
    /\ raiseRootSource \in {"Immediate", "None"}
    /\ raiseRootHasChild \in BOOLEAN
    /\ driverRaised \in BOOLEAN
    /\ terminalFailureCount \in 0..1
    /\ raisePhase \in {"Ready", "Raised", "Done"}
    /\ harnessPhase \in {"Ready", "Finalized", "Finished", "Consumed", "Disposed", "Done"}
    /\ lastAction \in
         {"Init", "BeginFinalize", "EarlyGateReturn", "RestoreReported",
          "WaitForTarget", "DispatchTarget", "FinishFinalize", "Finalize",
          "FailUpgradeDriver", "DrainPeer", "FinishFailedUpgrade",
          "ConsumeFailedUpgrade", "FinalizeFailedUpgrade",
          "CompleteCleanupDispatch", "AbortCleanupDispatch",
          "CompleteCleanupHandoff", "AbortCleanupHandoff", "DriverRaises",
          "DriverFinish", "DriverConsume", "DriverFinalize"}

SavedReportOnlyTerminal ==
    savedOtherReported => otherState = "Terminal"

Safety ==
    /\ LegacyTypeOK
    /\ ReportedOnlyTerminal
    /\ SavedReportOnlyTerminal
    /\ FinalStateReleased
    /\ OtherReportRestored
    /\ DriverReturnIsTerminal
    /\ DriverDisposeBeforePeerReturns
    /\ DriverDispatchStateRetainsObligation
    /\ DriverHandoffStateIsOwned
    /\ DriverCleanupIsOrdered
    /\ DriverRaiseHasProgress
    /\ DriverRaiseTerminalExactlyOnce

THEOREM InitImpliesSafety ==
    /\ InitialOtherReported \in BOOLEAN
    /\ DriverCloseMode \in {"Blocking", "Deferred"}
    /\ CleanupCloseMode \in {"Blocking", "Deferred"}
    /\ CleanupDispatchMode \in {"Atomic", "Split"}
    /\ CleanupHandoffMode \in {"Atomic", "Split"}
    /\ DriverRaiseMode = "Terminalize"
    => (LegacyInit => Safety)
<1>. QED BY DEF LegacyInit, Safety, LegacyTypeOK,
                ReportedOnlyTerminal, SavedReportOnlyTerminal,
                FinalStateReleased,
                OtherReportRestored, DriverReturnIsTerminal,
                DriverDisposeBeforePeerReturns,
                DriverDispatchStateRetainsObligation,
                DriverHandoffStateIsOwned,
                DriverCleanupIsOrdered,
                DriverRaiseHasProgress,
                DriverRaiseTerminalExactlyOnce

THEOREM NextPreservesSafety ==
    DriverRaiseMode = "Terminalize" /\ Safety /\ LegacyNext => Safety'
<1>. QED BY DEF Safety, LegacyTypeOK,
                ReportedOnlyTerminal, SavedReportOnlyTerminal,
                FinalStateReleased,
                OtherReportRestored, LegacyNext, BeginFinalize,
                EarlyGateReturn, RestoreReported,
                UserGateCannotReturnEarly, WaitForTarget,
                DispatchTarget, FinishFinalize,
                FailUpgradeDriver, DrainPeer,
                FinishFailedUpgrade, ConsumeFailedUpgrade,
                FinalizeFailedUpgrade, CompleteCleanupDispatch,
                AbortCleanupDispatch, CompleteCleanupHandoff,
                AbortCleanupHandoff, SplitCleanupDispatch,
                SplitCleanupHandoff,
                CleanupPhase, DriverRaises, DriverRaiseEffect,
                driverVars, driverRaiseVars,
                DriverReturnIsTerminal,
                DriverDisposeBeforePeerReturns,
                DriverDispatchStateRetainsObligation,
                DriverHandoffStateIsOwned,
                DriverCleanupIsOrdered,
                DriverRaiseHasProgress,
                DriverRaiseTerminalExactlyOnce

=============================================================================
