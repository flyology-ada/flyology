--------------------- MODULE CompletionSetFinalizeProof ---------------------
EXTENDS CompletionSetFinalize

SavedReportOnlyTerminal ==
    savedOtherReported => otherState = "Terminal"

Safety ==
    /\ TypeOK
    /\ ReportedOnlyTerminal
    /\ SavedReportOnlyTerminal
    /\ FinalStateReleased
    /\ OtherReportRestored
    /\ DriverReturnIsTerminal
    /\ DriverDisposeBeforePeerReturns
    /\ DriverDispatchStateRetainsObligation
    /\ DriverHandoffStateIsOwned
    /\ DriverCleanupIsOrdered

THEOREM InitImpliesSafety ==
    /\ InitialOtherReported \in BOOLEAN
    /\ DriverCloseMode \in {"Blocking", "Deferred"}
    /\ CleanupCloseMode \in {"Blocking", "Deferred"}
    /\ CleanupDispatchMode \in {"Atomic", "Split"}
    /\ CleanupHandoffMode \in {"Atomic", "Split"}
    => (Init => Safety)
<1>. QED BY DEF Init, Safety, TypeOK,
                ReportedOnlyTerminal, SavedReportOnlyTerminal,
                FinalStateReleased,
                OtherReportRestored, DriverReturnIsTerminal,
                DriverDisposeBeforePeerReturns,
                DriverDispatchStateRetainsObligation,
                DriverHandoffStateIsOwned,
                DriverCleanupIsOrdered

THEOREM NextPreservesSafety == Safety /\ Next => Safety'
<1>. QED BY DEF Safety, TypeOK,
                ReportedOnlyTerminal, SavedReportOnlyTerminal,
                FinalStateReleased,
                OtherReportRestored, Next, BeginFinalize,
                EarlyGateReturn, RestoreReported,
                UserGateCannotReturnEarly, WaitForTarget,
                DispatchTarget, FinishFinalize,
                FailUpgradeDriver, DrainPeer,
                FinishFailedUpgrade, ConsumeFailedUpgrade,
                FinalizeFailedUpgrade, CompleteCleanupDispatch,
                AbortCleanupDispatch, CompleteCleanupHandoff,
                AbortCleanupHandoff, SplitCleanupDispatch,
                SplitCleanupHandoff,
                CleanupPhase, driverVars,
                DriverReturnIsTerminal,
                DriverDisposeBeforePeerReturns,
                DriverDispatchStateRetainsObligation,
                DriverHandoffStateIsOwned,
                DriverCleanupIsOrdered

=============================================================================
