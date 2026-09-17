--------------------- MODULE CompletionSetFinalizeProof ---------------------
EXTENDS CompletionSetFinalize

\* Legacy finalization and owner-local ATC use separate preservation proofs.
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

ATCRecordType ==
    atc \in [stage : {"Idle", "Driving", "Requested", "Returned", "Delivered", "Used", "Cancelled"},
             depth : 0..1, stabilizing : BOOLEAN, dirty : 0..1,
             source : {"Immediate", "Dependency", "None"}, deadline : BOOLEAN,
             child : BOOLEAN, childState : {"Vacant", "Pending", "Terminal"}, childDeadline : BOOLEAN,
             root : {"Pending", "Terminal"}, gate : {"Pending", "Terminal"},
             rootOutcome : {"None", "Succeeded", "Cancelled"}, gateOutcome : {"None", "Succeeded", "Failed"},
             deferral : 0..2, requested : BOOLEAN, delivered : BOOLEAN, waitFailed : BOOLEAN,
             action : {"Init", "ATCDrive", "ATCProtectedReturn", "ATCDriverReturn",
                       "ATCStableDeliver", "ATCBrokenDeliver", "ATCUse", "ATCCancel"}]

ATCDeferredSafety ==
    /\ ATCRecordType
    /\ ATCResumeConsistent
    /\ ATCUseHasProgress
    /\ ATCCancellationPropagates
    /\ (atc.stage \in {"Idle", "Driving", "Requested", "Returned"} => ~atc.delivered)
    /\ (atc.stage \in {"Driving", "Requested", "Returned"} => atc.deferral = 1)
    /\ (atc.stage = "Returned" => atc.root = "Terminal" \/ atc.source = "Immediate")
    /\ (atc.stage \in {"Delivered", "Used", "Cancelled"} => atc.delivered)

THEOREM ATCInitIsSafe ==
    ATCMode = "Deferred" /\ Init => ATCDeferredSafety
<1>. QED BY DEF Init, ATCInitial, ATCDeferredSafety, ATCRecordType,
                ATCResumeConsistent, ATCUseHasProgress,
                ATCCancellationPropagates

THEOREM ATCNextPreservesSafety ==
    ATCReturn \in {"Terminal", "Rearm"} /\ ATCMode = "Deferred"
    /\ ATCDeferredSafety /\ ATCNext => ATCDeferredSafety'
<1>1. ATCMode = "Deferred" /\ ATCDeferredSafety /\ ATCDrive => ATCDeferredSafety'
<2>. QED BY DEF ATCDeferredSafety, ATCRecordType, ATCResumeConsistent,
                ATCUseHasProgress, ATCCancellationPropagates, ATCDrive
<1>2. ATCMode = "Deferred" /\ ATCDeferredSafety /\ ATCProtectedReturn => ATCDeferredSafety'
<2>. QED BY DEF ATCDeferredSafety, ATCRecordType, ATCResumeConsistent,
                ATCUseHasProgress, ATCCancellationPropagates, ATCProtectedReturn
<1>3. ATCReturn \in {"Terminal", "Rearm"} /\ ATCMode = "Deferred"
       /\ ATCDeferredSafety /\ ATCDriverReturn => ATCDeferredSafety'
<2>. QED BY DEF ATCDeferredSafety, ATCRecordType, ATCResumeConsistent,
                ATCUseHasProgress, ATCCancellationPropagates, ATCDriverReturn
<1>4. ATCMode = "Deferred" /\ ATCDeferredSafety /\ ATCStableDeliver => ATCDeferredSafety'
<2>. QED BY DEF ATCDeferredSafety, ATCRecordType, ATCResumeConsistent,
                ATCUseHasProgress, ATCCancellationPropagates, ATCStableDeliver
<1>5. ATCMode = "Deferred" /\ ATCDeferredSafety /\ ATCBrokenDeliver => ATCDeferredSafety'
<2>. QED BY DEF ATCDeferredSafety, ATCRecordType, ATCResumeConsistent,
                ATCUseHasProgress, ATCCancellationPropagates, ATCBrokenDeliver
<1>6. ATCMode = "Deferred" /\ ATCDeferredSafety /\ ATCUse => ATCDeferredSafety'
<2>. QED BY DEF ATCDeferredSafety, ATCRecordType, ATCResumeConsistent,
                ATCUseHasProgress, ATCCancellationPropagates, ATCUse
<1>7. ATCMode = "Deferred" /\ ATCDeferredSafety /\ ATCCancel => ATCDeferredSafety'
<2>. QED BY DEF ATCDeferredSafety, ATCRecordType, ATCResumeConsistent,
                ATCUseHasProgress, ATCCancellationPropagates, ATCCancel
<1>. QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6, <1>7 DEF ATCNext

=============================================================================
