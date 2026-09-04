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

THEOREM InitImpliesSafety ==
    InitialOtherReported \in BOOLEAN => (Init => Safety)
<1>. QED BY DEF Init, Safety, TypeOK,
                ReportedOnlyTerminal, SavedReportOnlyTerminal,
                FinalStateReleased,
                OtherReportRestored

THEOREM NextPreservesSafety == Safety /\ Next => Safety'
<1>. QED BY DEF Safety, TypeOK,
                ReportedOnlyTerminal, SavedReportOnlyTerminal,
                FinalStateReleased,
                OtherReportRestored, Next, BeginFinalize,
                EarlyGateReturn, RestoreReported,
                UserGateCannotReturnEarly, WaitForTarget,
                DispatchTarget, FinishFinalize

=============================================================================
