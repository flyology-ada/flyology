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
    /\ DriverCleanupIsOrdered

THEOREM InitImpliesSafety ==
    /\ InitialOtherReported \in BOOLEAN
    /\ DriverCloseMode \in {"Blocking", "Deferred"}
    => (Init => Safety)
<1>. QED BY DEF Init, Safety, TypeOK,
                ReportedOnlyTerminal, SavedReportOnlyTerminal,
                FinalStateReleased,
                OtherReportRestored, DriverReturnIsTerminal,
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
                FinishFailedUpgrade, driverVars,
                DriverReturnIsTerminal,
                DriverCleanupIsOrdered

=============================================================================
