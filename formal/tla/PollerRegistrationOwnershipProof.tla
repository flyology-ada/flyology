---------------- MODULE PollerRegistrationOwnershipProof -----------------
EXTENDS PollerRegistrationOwnership

CoreSafety ==
    /\ LegacyTypeOK
    /\ SingleRegistrationWriter
    /\ CancellationQueueReferencesLiveFiber
    /\ QueuedCancellationMatchesWaitGeneration
    /\ QueuedCancellationOwnsTarget
    /\ PendingCancellationHasWake
    /\ NoStaleCancellation

Safety ==
    /\ CoreSafety
    /\ ReplacementWaitHasKernelInterest
    /\ QueuedLinkDoesNotSuppressReplacementArm
    /\ CurrentReusedWaitIsArmed
    /\ StaleLinkDoesNotSuppressReuseArm
    /\ ReusedReadinessDelivered

THEOREM InitImpliesSafety ==
    /\ CancelMode = "Deferred"
    /\ DeliveryMode = "CancellationOwned"
    /\ ReplacementArmMode = "IgnoreQueued"
    /\ ReuseArmMode = "AlwaysRearm"
    /\ SelectedSource \in {"Readiness", "Timer"}
    => (Init => Safety)
<1>. QED BY DEF Init, Safety, CoreSafety, LegacyTypeOK,
                SingleRegistrationWriter,
                CancellationQueueReferencesLiveFiber,
                QueuedCancellationMatchesWaitGeneration,
                QueuedCancellationOwnsTarget, PendingCancellationHasWake,
                NoStaleCancellation, ReplacementWaitHasKernelInterest,
                QueuedLinkDoesNotSuppressReplacementArm,
                CurrentReusedWaitIsArmed,
                StaleLinkDoesNotSuppressReuseArm,
                ReusedReadinessDelivered, reuseVars

THEOREM NextPreservesSafety ==
    /\ CancelMode = "Deferred"
    /\ DeliveryMode = "CancellationOwned"
    /\ ReplacementArmMode = "IgnoreQueued"
    /\ ReuseArmMode = "AlwaysRearm"
    /\ SelectedSource \in {"Readiness", "Timer"}
    /\ Safety
    /\ Next
    => Safety'
<1>1. /\ CancelMode = "Deferred"
       /\ DeliveryMode = "CancellationOwned"
       /\ ReplacementArmMode = "IgnoreQueued"
       /\ ReuseArmMode = "AlwaysRearm"
       /\ SelectedSource \in {"Readiness", "Timer"}
       /\ Safety
       /\ Next
       => CoreSafety'
<2>. QED BY DEF Safety, CoreSafety, LegacyTypeOK,
                SingleRegistrationWriter,
                CancellationQueueReferencesLiveFiber,
                QueuedCancellationMatchesWaitGeneration,
                QueuedCancellationOwnsTarget, PendingCancellationHasWake,
                NoStaleCancellation, Next, CancellationNext, ReuseNext,
                IndexNext, coreVars, BeginWaitBatch, ForeignWake,
                DrainBudget, DeliverTarget, StartReplacement,
                ReregisterTarget, ReapTarget, DrainRemaining,
                DrainReplacement, DrainReused, DrainTimer,
                DeliverReplacement, BeginOldWait, CloseAndReuse,
                BeginReusedWait, DeliverReusedWait, reuseVars
<1>2. /\ CancelMode = "Deferred"
       /\ DeliveryMode = "CancellationOwned"
       /\ ReplacementArmMode = "IgnoreQueued"
       /\ ReuseArmMode = "AlwaysRearm"
       /\ SelectedSource \in {"Readiness", "Timer"}
       /\ Safety
       /\ Next
       => ReplacementWaitHasKernelInterest'
<2>. QED BY DEF Safety, CoreSafety, ReplacementWaitHasKernelInterest,
                Next, CancellationNext, ReuseNext, IndexNext,
                BeginWaitBatch, ForeignWake, DrainBudget,
                DeliverTarget, StartReplacement, ReregisterTarget,
                ReapTarget, DrainRemaining, DrainReplacement, DrainReused,
                DrainTimer, DeliverReplacement, BeginOldWait,
                CloseAndReuse, BeginReusedWait, DeliverReusedWait,
                reuseVars
<1>3. /\ CancelMode = "Deferred"
       /\ DeliveryMode = "CancellationOwned"
       /\ ReplacementArmMode = "IgnoreQueued"
       /\ ReuseArmMode = "AlwaysRearm"
       /\ SelectedSource \in {"Readiness", "Timer"}
       /\ Safety
       /\ Next
       => QueuedLinkDoesNotSuppressReplacementArm'
<2>. QED BY DEF Safety, CoreSafety,
                QueuedLinkDoesNotSuppressReplacementArm, Next,
                CancellationNext, ReuseNext, IndexNext,
                BeginWaitBatch, ForeignWake, DrainBudget, DeliverTarget,
                StartReplacement, ReregisterTarget, ReapTarget,
                DrainRemaining, DrainReplacement, DrainReused, DrainTimer,
                DeliverReplacement, BeginOldWait, CloseAndReuse,
                BeginReusedWait, DeliverReusedWait, reuseVars
<1>4. /\ CancelMode = "Deferred"
       /\ DeliveryMode = "CancellationOwned"
       /\ ReplacementArmMode = "IgnoreQueued"
       /\ ReuseArmMode = "AlwaysRearm"
       /\ SelectedSource \in {"Readiness", "Timer"}
       /\ Safety
       /\ Next
       => CurrentReusedWaitIsArmed'
<2>. QED BY DEF Safety, CoreSafety, CurrentReusedWaitIsArmed,
                Next, CancellationNext, ReuseNext, IndexNext,
                BeginWaitBatch, ForeignWake, DrainBudget,
                DeliverTarget, StartReplacement, ReregisterTarget,
                ReapTarget, DrainRemaining, DrainReplacement, DrainReused,
                DrainTimer, DeliverReplacement, BeginOldWait,
                CloseAndReuse, BeginReusedWait, DeliverReusedWait,
                reuseVars
<1>5. /\ CancelMode = "Deferred"
       /\ DeliveryMode = "CancellationOwned"
       /\ ReplacementArmMode = "IgnoreQueued"
       /\ ReuseArmMode = "AlwaysRearm"
       /\ SelectedSource \in {"Readiness", "Timer"}
       /\ Safety
       /\ Next
       => StaleLinkDoesNotSuppressReuseArm'
<2>. QED BY DEF Safety, CoreSafety, StaleLinkDoesNotSuppressReuseArm,
                Next, CancellationNext, ReuseNext, IndexNext,
                BeginWaitBatch, ForeignWake, DrainBudget,
                DeliverTarget, StartReplacement, ReregisterTarget,
                ReapTarget, DrainRemaining, DrainReplacement, DrainReused,
                DrainTimer, DeliverReplacement, BeginOldWait,
                CloseAndReuse, BeginReusedWait, DeliverReusedWait,
                reuseVars
<1>6. /\ CancelMode = "Deferred"
       /\ DeliveryMode = "CancellationOwned"
       /\ ReplacementArmMode = "IgnoreQueued"
       /\ ReuseArmMode = "AlwaysRearm"
       /\ SelectedSource \in {"Readiness", "Timer"}
       /\ Safety
       /\ Next
       => ReusedReadinessDelivered'
<2>. QED BY DEF Safety, CoreSafety, CurrentReusedWaitIsArmed,
                ReusedReadinessDelivered,
                Next, CancellationNext, ReuseNext, IndexNext,
                BeginWaitBatch, ForeignWake, DrainBudget,
                DeliverTarget, StartReplacement, ReregisterTarget,
                ReapTarget, DrainRemaining, DrainReplacement, DrainReused,
                DrainTimer, DeliverReplacement, BeginOldWait,
                CloseAndReuse, BeginReusedWait, DeliverReusedWait,
                reuseVars
<1>. QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6 DEF Safety

=============================================================================
