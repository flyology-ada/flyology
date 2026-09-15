---------------- MODULE PollerRegistrationOwnershipProof -----------------
EXTENDS PollerRegistrationOwnership

CoreSafety ==
    /\ LegacyTypeOK
    /\ SingleRegistrationWriter
    /\ CancellationQueueReferencesLiveFiber
    /\ QueuedCancellationMatchesWaitGeneration
    /\ QueuedCancellationOwnsTarget
    /\ QueuedCancellationRetainsWait
    /\ DrainedReplacementExcludesTargetWait
    /\ PendingCancellationHasWake
    /\ NoStaleCancellation

LegacySafety ==
    /\ CoreSafety
    /\ ReplacementWaitHasKernelInterest
    /\ QueuedLinkDoesNotSuppressReplacementArm
    /\ CurrentReusedWaitIsArmed
    /\ StaleLinkDoesNotSuppressReuseArm
    /\ ReusedReadinessDelivered

IndexSafety ==
    /\ IndexTypeOK
    /\ LiveInterestHasIndexedRegistration
    /\ DisabledOneShotRetained
    /\ QueuedCancellationHasIndexedOwner
    /\ StaleDescriptorHasIndexedRegistration
    /\ DescriptorIndexExact

Safety == LegacySafety /\ IndexSafety

ProofAssumptions ==
    /\ CancelMode = "Deferred"
    /\ DeliveryMode = "CancellationOwned"
    /\ ReplacementArmMode = "IgnoreQueued"
    /\ ReuseArmMode = "AlwaysRearm"
    /\ RegistrationMode = "IndexedRetained"
    /\ SelectedSource \in {"Readiness", "Timer"}

LegacyPreservation == ProofAssumptions /\ LegacySafety
IndexPreservation == LegacyPreservation /\ IndexSafety

THEOREM InitImpliesSafety ==
    /\ CancelMode = "Deferred"
    /\ DeliveryMode = "CancellationOwned"
    /\ ReplacementArmMode = "IgnoreQueued"
    /\ ReuseArmMode = "AlwaysRearm"
    /\ RegistrationMode = "IndexedRetained"
    /\ SelectedSource \in {"Readiness", "Timer"}
    => (Init => Safety)
<1>. QED BY DEF Init, Safety, LegacySafety, IndexSafety,
                CoreSafety, LegacyTypeOK, IndexTypeOK,
                SingleRegistrationWriter,
                CancellationQueueReferencesLiveFiber,
                QueuedCancellationMatchesWaitGeneration,
                QueuedCancellationOwnsTarget,
                QueuedCancellationRetainsWait,
                DrainedReplacementExcludesTargetWait,
                PendingCancellationHasWake,
                NoStaleCancellation, ReplacementWaitHasKernelInterest,
                QueuedLinkDoesNotSuppressReplacementArm,
                CurrentReusedWaitIsArmed,
                StaleLinkDoesNotSuppressReuseArm,
                ReusedReadinessDelivered,
                LiveInterestHasIndexedRegistration,
                DisabledOneShotRetained,
                QueuedCancellationHasIndexedOwner,
                StaleDescriptorHasIndexedRegistration,
                DescriptorIndexExact, reuseVars

THEOREM NextPreservesLegacySafety ==
    /\ CancelMode = "Deferred"
    /\ DeliveryMode = "CancellationOwned"
    /\ ReplacementArmMode = "IgnoreQueued"
    /\ ReuseArmMode = "AlwaysRearm"
    /\ RegistrationMode = "IndexedRetained"
    /\ SelectedSource \in {"Readiness", "Timer"}
    /\ LegacySafety
    /\ Next
    => LegacySafety'
<1>1. /\ CancelMode = "Deferred"
       /\ DeliveryMode = "CancellationOwned"
       /\ ReplacementArmMode = "IgnoreQueued"
       /\ ReuseArmMode = "AlwaysRearm"
       /\ RegistrationMode = "IndexedRetained"
       /\ SelectedSource \in {"Readiness", "Timer"}
       /\ LegacySafety
       /\ Next
       => CoreSafety'
<2>. QED BY DEF LegacySafety, CoreSafety, LegacyTypeOK,
                SingleRegistrationWriter,
                CancellationQueueReferencesLiveFiber,
                QueuedCancellationMatchesWaitGeneration,
                QueuedCancellationOwnsTarget,
                QueuedCancellationRetainsWait,
                DrainedReplacementExcludesTargetWait,
                PendingCancellationHasWake,
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
       /\ RegistrationMode = "IndexedRetained"
       /\ SelectedSource \in {"Readiness", "Timer"}
       /\ LegacySafety
       /\ Next
       => ReplacementWaitHasKernelInterest'
<2>. QED BY DEF LegacySafety, CoreSafety, ReplacementWaitHasKernelInterest,
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
       /\ RegistrationMode = "IndexedRetained"
       /\ SelectedSource \in {"Readiness", "Timer"}
       /\ LegacySafety
       /\ Next
       => QueuedLinkDoesNotSuppressReplacementArm'
<2>. QED BY DEF LegacySafety, CoreSafety,
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
       /\ RegistrationMode = "IndexedRetained"
       /\ SelectedSource \in {"Readiness", "Timer"}
       /\ LegacySafety
       /\ Next
       => CurrentReusedWaitIsArmed'
<2>. QED BY DEF LegacySafety, CoreSafety, CurrentReusedWaitIsArmed,
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
       /\ RegistrationMode = "IndexedRetained"
       /\ SelectedSource \in {"Readiness", "Timer"}
       /\ LegacySafety
       /\ Next
       => StaleLinkDoesNotSuppressReuseArm'
<2>1. LegacyPreservation /\ ReuseNext
       => StaleLinkDoesNotSuppressReuseArm'
<3>. QED BY DEF LegacyPreservation, ProofAssumptions, LegacySafety,
                CoreSafety, StaleLinkDoesNotSuppressReuseArm,
                ReuseNext, BeginOldWait, CloseAndReuse,
                BeginReusedWait, DeliverReusedWait, reuseVars
<2>2. LegacyPreservation /\ (CancellationNext \/ IndexNext)
       => StaleLinkDoesNotSuppressReuseArm'
<3>. QED BY DEF LegacyPreservation, ProofAssumptions, LegacySafety,
                CoreSafety, StaleLinkDoesNotSuppressReuseArm,
                CancellationNext, IndexNext, BeginWaitBatch, ForeignWake,
                DrainBudget, DeliverTarget, StartReplacement,
                ReregisterTarget, ReapTarget, DrainRemaining,
                DrainReplacement, DrainReused, DrainTimer,
                DeliverReplacement, BeginIndexedWait,
                DeliverIndexedOneShot, RearmIndexedOneShot,
                PublishIndexedReadiness, reuseVars
<2>. QED BY <2>1, <2>2 DEF Next, LegacyPreservation,
             ProofAssumptions
<1>6. /\ CancelMode = "Deferred"
       /\ DeliveryMode = "CancellationOwned"
       /\ ReplacementArmMode = "IgnoreQueued"
       /\ ReuseArmMode = "AlwaysRearm"
       /\ RegistrationMode = "IndexedRetained"
       /\ SelectedSource \in {"Readiness", "Timer"}
       /\ LegacySafety
       /\ Next
       => ReusedReadinessDelivered'
<2>1. LegacyPreservation /\ ReuseNext => ReusedReadinessDelivered'
<3>. QED BY DEF LegacyPreservation, ProofAssumptions, LegacySafety,
                CoreSafety, CurrentReusedWaitIsArmed,
                ReusedReadinessDelivered, ReuseNext, BeginOldWait,
                CloseAndReuse, BeginReusedWait, DeliverReusedWait,
                reuseVars
<2>2. LegacyPreservation /\ (CancellationNext \/ IndexNext)
       => ReusedReadinessDelivered'
<3>. QED BY DEF LegacyPreservation, ProofAssumptions, LegacySafety,
                CoreSafety, ReusedReadinessDelivered,
                CancellationNext, IndexNext, BeginWaitBatch, ForeignWake,
                DrainBudget, DeliverTarget, StartReplacement,
                ReregisterTarget, ReapTarget, DrainRemaining,
                DrainReplacement, DrainReused, DrainTimer,
                DeliverReplacement, BeginIndexedWait,
                DeliverIndexedOneShot, RearmIndexedOneShot,
                PublishIndexedReadiness, reuseVars
<2>. QED BY <2>1, <2>2 DEF Next, LegacyPreservation,
             ProofAssumptions
<1>. QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6 DEF LegacySafety

THEOREM NextPreservesIndexSafety ==
    IndexPreservation /\ Next => IndexSafety'
<1>1. IndexPreservation /\ BeginWaitBatch => IndexSafety'
<2>. QED BY DEF IndexPreservation, LegacyPreservation,
                ProofAssumptions, LegacySafety, IndexSafety,
                CoreSafety, IndexTypeOK,
                LiveInterestHasIndexedRegistration,
                DisabledOneShotRetained,
                QueuedCancellationHasIndexedOwner,
                StaleDescriptorHasIndexedRegistration,
                DescriptorIndexExact,
                BeginWaitBatch, reuseVars, retainedVars
<1>2. IndexPreservation /\ ForeignWake => IndexSafety'
<2>1. IndexPreservation /\ ForeignWake => IndexTypeOK'
<3>. QED BY DEF IndexPreservation, LegacyPreservation,
                ProofAssumptions, LegacySafety, IndexSafety,
                CoreSafety, IndexTypeOK, ForeignWake,
                reuseVars, retainedVars
<2>2. IndexPreservation /\ ForeignWake
       => LiveInterestHasIndexedRegistration'
<3>. QED BY DEF IndexPreservation, LegacyPreservation,
                ProofAssumptions, LegacySafety, IndexSafety,
                CoreSafety, DrainedReplacementExcludesTargetWait,
                LiveInterestHasIndexedRegistration,
                ForeignWake, reuseVars, retainedVars
<2>3. IndexPreservation /\ ForeignWake => DisabledOneShotRetained'
<3>. QED BY DEF IndexPreservation, LegacyPreservation,
                ProofAssumptions, LegacySafety, IndexSafety,
                CoreSafety,
                DisabledOneShotRetained,
                ForeignWake, reuseVars, retainedVars
<2>4. IndexPreservation /\ ForeignWake
       => QueuedCancellationHasIndexedOwner'
<3>. QED BY DEF IndexPreservation, LegacyPreservation,
                ProofAssumptions, LegacySafety, IndexSafety,
                CoreSafety,
                QueuedCancellationHasIndexedOwner,
                ForeignWake, reuseVars, retainedVars
<2>5. IndexPreservation /\ ForeignWake
       => StaleDescriptorHasIndexedRegistration'
<3>. QED BY DEF IndexPreservation, LegacyPreservation,
                ProofAssumptions, LegacySafety, IndexSafety,
                CoreSafety,
                StaleDescriptorHasIndexedRegistration,
                ForeignWake, reuseVars, retainedVars
<2>6. IndexPreservation /\ ForeignWake => DescriptorIndexExact'
<3>. QED BY DEF IndexPreservation, LegacyPreservation,
                ProofAssumptions, LegacySafety, IndexSafety,
                CoreSafety, LiveInterestHasIndexedRegistration,
                DescriptorIndexExact,
                ForeignWake, reuseVars, retainedVars
<2>. QED BY <2>1, <2>2, <2>3, <2>4, <2>5, <2>6
             DEF IndexSafety
<1>3. IndexPreservation /\ DeliverTarget => IndexSafety'
<2>1. IndexPreservation /\ DeliverTarget => IndexTypeOK'
<3>. QED BY DEF IndexPreservation, LegacyPreservation,
                ProofAssumptions, LegacySafety, IndexSafety,
                CoreSafety, IndexTypeOK, DeliverTarget,
                reuseVars, indexVars
<2>2. IndexPreservation /\ DeliverTarget
       => LiveInterestHasIndexedRegistration'
<3>. QED BY DEF IndexPreservation, LegacyPreservation,
                ProofAssumptions, LegacySafety, IndexSafety,
                CoreSafety, QueuedCancellationRetainsWait,
                LiveInterestHasIndexedRegistration,
                DeliverTarget, reuseVars, indexVars
<2>3. IndexPreservation /\ DeliverTarget => DisabledOneShotRetained'
<3>. QED BY DEF IndexPreservation, LegacyPreservation,
                ProofAssumptions, LegacySafety, IndexSafety,
                CoreSafety, DisabledOneShotRetained,
                DeliverTarget, reuseVars, indexVars
<2>4. IndexPreservation /\ DeliverTarget => DescriptorIndexExact'
<3>. QED BY DEF IndexPreservation, LegacyPreservation,
                ProofAssumptions, LegacySafety, IndexSafety,
                CoreSafety, DescriptorIndexExact,
                DeliverTarget, reuseVars, indexVars
<2>5. IndexPreservation /\ DeliverTarget
       => QueuedCancellationHasIndexedOwner'
<3>. QED BY DEF IndexPreservation, LegacyPreservation,
                ProofAssumptions, LegacySafety, IndexSafety,
                CoreSafety, QueuedCancellationHasIndexedOwner,
                DeliverTarget, reuseVars, indexVars
<2>6. IndexPreservation /\ DeliverTarget
       => StaleDescriptorHasIndexedRegistration'
<3>. QED BY DEF IndexPreservation, LegacyPreservation,
                ProofAssumptions, LegacySafety, IndexSafety,
                CoreSafety, StaleDescriptorHasIndexedRegistration,
                DeliverTarget, reuseVars, indexVars
<2>. QED BY <2>1, <2>2, <2>3, <2>4, <2>5, <2>6
             DEF IndexSafety
<1>4. IndexPreservation /\ DrainBudget => IndexSafety'
<2>. QED BY DEF IndexPreservation, LegacyPreservation,
                ProofAssumptions, LegacySafety, IndexSafety,
                CoreSafety, IndexTypeOK,
                LiveInterestHasIndexedRegistration,
                DisabledOneShotRetained,
                QueuedCancellationHasIndexedOwner,
                StaleDescriptorHasIndexedRegistration,
                DescriptorIndexExact,
                DrainBudget, reuseVars, indexVars
<1>5. IndexPreservation /\ StartReplacement => IndexSafety'
<2>. QED BY DEF IndexPreservation, LegacyPreservation,
                ProofAssumptions, LegacySafety, IndexSafety,
                CoreSafety, IndexTypeOK,
                LiveInterestHasIndexedRegistration,
                DisabledOneShotRetained,
                QueuedCancellationHasIndexedOwner,
                StaleDescriptorHasIndexedRegistration,
                DescriptorIndexExact,
                StartReplacement, reuseVars, retainedVars
<1>6. IndexPreservation /\ ReregisterTarget => IndexSafety'
<2>. QED BY DEF IndexPreservation, LegacyPreservation,
                ProofAssumptions, LegacySafety, IndexSafety,
                CoreSafety, IndexTypeOK,
                LiveInterestHasIndexedRegistration,
                DisabledOneShotRetained,
                QueuedCancellationHasIndexedOwner,
                StaleDescriptorHasIndexedRegistration,
                DescriptorIndexExact,
                ReregisterTarget, reuseVars, retainedVars
<1>7. IndexPreservation /\ ReapTarget => IndexSafety'
<2>. QED BY DEF IndexPreservation, LegacyPreservation,
                ProofAssumptions, LegacySafety, IndexSafety,
                CoreSafety, IndexTypeOK,
                LiveInterestHasIndexedRegistration,
                DisabledOneShotRetained,
                QueuedCancellationHasIndexedOwner,
                StaleDescriptorHasIndexedRegistration,
                DescriptorIndexExact,
                ReapTarget, reuseVars, retainedVars
<1>8. IndexPreservation /\ DrainRemaining => IndexSafety'
<2>1. IndexPreservation /\ DrainReplacement => IndexSafety'
<3>. QED BY DEF IndexPreservation, LegacyPreservation,
                ProofAssumptions, LegacySafety, IndexSafety,
                CoreSafety, IndexTypeOK,
                LiveInterestHasIndexedRegistration,
                DisabledOneShotRetained,
                QueuedCancellationHasIndexedOwner,
                StaleDescriptorHasIndexedRegistration,
                DescriptorIndexExact,
                DrainReplacement, reuseVars, indexVars
<2>2. IndexPreservation /\ DrainReused => IndexSafety'
<3>. QED BY DEF IndexPreservation, LegacyPreservation,
                ProofAssumptions, LegacySafety, IndexSafety,
                CoreSafety, IndexTypeOK,
                LiveInterestHasIndexedRegistration,
                DisabledOneShotRetained,
                QueuedCancellationHasIndexedOwner,
                StaleDescriptorHasIndexedRegistration,
                DescriptorIndexExact,
                DrainReused, reuseVars, indexVars
<2>3. IndexPreservation /\ DrainTimer => IndexSafety'
<3>. QED BY DEF IndexPreservation, LegacyPreservation,
                ProofAssumptions, LegacySafety, IndexSafety,
                CoreSafety, IndexTypeOK,
                LiveInterestHasIndexedRegistration,
                DisabledOneShotRetained,
                QueuedCancellationHasIndexedOwner,
                StaleDescriptorHasIndexedRegistration,
                DescriptorIndexExact,
                DrainTimer, reuseVars, retainedVars
<2>. QED BY <2>1, <2>2, <2>3 DEF DrainRemaining
<1>9. IndexPreservation /\ DeliverReplacement => IndexSafety'
<2>1. IndexPreservation /\ DeliverReplacement => IndexTypeOK'
<3>. QED BY DEF IndexPreservation, LegacyPreservation,
                ProofAssumptions, LegacySafety, IndexSafety,
                CoreSafety, IndexTypeOK, DeliverReplacement,
                reuseVars, retainedVars
<2>2. IndexPreservation /\ DeliverReplacement
       => LiveInterestHasIndexedRegistration'
<3>. QED BY DEF IndexPreservation, LegacyPreservation,
                ProofAssumptions, LegacySafety, IndexSafety,
                CoreSafety, DrainedReplacementExcludesTargetWait,
                LiveInterestHasIndexedRegistration,
                DeliverReplacement, reuseVars, retainedVars
<2>3. IndexPreservation /\ DeliverReplacement
       => DisabledOneShotRetained'
<3>. QED BY DEF IndexPreservation, LegacyPreservation,
                ProofAssumptions, LegacySafety, IndexSafety,
                CoreSafety,
                DisabledOneShotRetained,
                DeliverReplacement, reuseVars, retainedVars
<2>4. IndexPreservation /\ DeliverReplacement
       => QueuedCancellationHasIndexedOwner'
<3>. QED BY DEF IndexPreservation, LegacyPreservation,
                ProofAssumptions, LegacySafety, IndexSafety,
                CoreSafety,
                QueuedCancellationHasIndexedOwner,
                DeliverReplacement, reuseVars, retainedVars
<2>5. IndexPreservation /\ DeliverReplacement
       => StaleDescriptorHasIndexedRegistration'
<3>. QED BY DEF IndexPreservation, LegacyPreservation,
                ProofAssumptions, LegacySafety, IndexSafety,
                CoreSafety,
                StaleDescriptorHasIndexedRegistration,
                DeliverReplacement, reuseVars, retainedVars
<2>6. IndexPreservation /\ DeliverReplacement
       => DescriptorIndexExact'
<3>. QED BY DEF IndexPreservation, LegacyPreservation,
                ProofAssumptions, LegacySafety, IndexSafety,
                CoreSafety, LiveInterestHasIndexedRegistration,
                DescriptorIndexExact,
                DeliverReplacement, reuseVars, retainedVars
<2>. QED BY <2>1, <2>2, <2>3, <2>4, <2>5, <2>6
             DEF IndexSafety
<1>10. IndexPreservation /\ BeginOldWait => IndexSafety'
<2>. QED BY DEF IndexPreservation, LegacyPreservation,
                ProofAssumptions, LegacySafety, IndexSafety,
                CoreSafety, IndexTypeOK,
                LiveInterestHasIndexedRegistration,
                DisabledOneShotRetained,
                QueuedCancellationHasIndexedOwner,
                StaleDescriptorHasIndexedRegistration,
                DescriptorIndexExact,
                BeginOldWait, retainedVars
<1>11. IndexPreservation /\ CloseAndReuse => IndexSafety'
<2>. QED BY DEF IndexPreservation, LegacyPreservation,
                ProofAssumptions, LegacySafety, IndexSafety,
                CoreSafety, IndexTypeOK,
                LiveInterestHasIndexedRegistration,
                DisabledOneShotRetained,
                QueuedCancellationHasIndexedOwner,
                StaleDescriptorHasIndexedRegistration,
                DescriptorIndexExact,
                CloseAndReuse, indexVars
<1>12. IndexPreservation /\ BeginReusedWait => IndexSafety'
<2>. QED BY DEF IndexPreservation, LegacyPreservation,
                ProofAssumptions, LegacySafety, IndexSafety,
                CoreSafety, IndexTypeOK,
                LiveInterestHasIndexedRegistration,
                DisabledOneShotRetained,
                QueuedCancellationHasIndexedOwner,
                StaleDescriptorHasIndexedRegistration,
                DescriptorIndexExact,
                BeginReusedWait, indexVars
<1>13. IndexPreservation /\ DeliverReusedWait => IndexSafety'
<2>. QED BY DEF IndexPreservation, LegacyPreservation,
                ProofAssumptions, LegacySafety, IndexSafety,
                CoreSafety, IndexTypeOK,
                LiveInterestHasIndexedRegistration,
                DisabledOneShotRetained,
                QueuedCancellationHasIndexedOwner,
                StaleDescriptorHasIndexedRegistration,
                DescriptorIndexExact,
                DeliverReusedWait, retainedVars
<1>14. IndexPreservation /\ BeginIndexedWait => IndexSafety'
<2>. QED BY DEF IndexPreservation, LegacyPreservation,
                ProofAssumptions, LegacySafety, IndexSafety,
                CoreSafety, IndexTypeOK,
                LiveInterestHasIndexedRegistration,
                DisabledOneShotRetained,
                QueuedCancellationHasIndexedOwner,
                StaleDescriptorHasIndexedRegistration,
                DescriptorIndexExact,
                BeginIndexedWait, reuseVars
<1>15. IndexPreservation /\ DeliverIndexedOneShot => IndexSafety'
<2>. QED BY DEF IndexPreservation, LegacyPreservation,
                ProofAssumptions, LegacySafety, IndexSafety,
                CoreSafety, IndexTypeOK,
                LiveInterestHasIndexedRegistration,
                DisabledOneShotRetained,
                QueuedCancellationHasIndexedOwner,
                StaleDescriptorHasIndexedRegistration,
                DescriptorIndexExact,
                DeliverIndexedOneShot, reuseVars
<1>16. IndexPreservation /\ RearmIndexedOneShot => IndexSafety'
<2>. QED BY DEF IndexPreservation, LegacyPreservation,
                ProofAssumptions, LegacySafety, IndexSafety,
                CoreSafety, IndexTypeOK,
                LiveInterestHasIndexedRegistration,
                DisabledOneShotRetained,
                QueuedCancellationHasIndexedOwner,
                StaleDescriptorHasIndexedRegistration,
                DescriptorIndexExact,
                RearmIndexedOneShot, reuseVars
<1>17. IndexPreservation /\ PublishIndexedReadiness => IndexSafety'
<2>. QED BY DEF IndexPreservation, LegacyPreservation,
                ProofAssumptions, LegacySafety, IndexSafety,
                CoreSafety, IndexTypeOK,
                LiveInterestHasIndexedRegistration,
                DisabledOneShotRetained,
                QueuedCancellationHasIndexedOwner,
                StaleDescriptorHasIndexedRegistration,
                DescriptorIndexExact,
                PublishIndexedReadiness, reuseVars
<1>. QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6, <1>7,
             <1>8, <1>9, <1>10, <1>11, <1>12, <1>13, <1>14,
             <1>15, <1>16, <1>17
             DEF Next, CancellationNext, ReuseNext, IndexNext

THEOREM NextPreservesSafety ==
    /\ CancelMode = "Deferred"
    /\ DeliveryMode = "CancellationOwned"
    /\ ReplacementArmMode = "IgnoreQueued"
    /\ ReuseArmMode = "AlwaysRearm"
    /\ RegistrationMode = "IndexedRetained"
    /\ SelectedSource \in {"Readiness", "Timer"}
    /\ Safety
    /\ Next
    => Safety'
<1>1. ProofAssumptions /\ Safety /\ Next => LegacySafety'
<2>. QED BY NextPreservesLegacySafety
             DEF ProofAssumptions, Safety
<1>2. ProofAssumptions /\ Safety /\ Next => IndexSafety'
<2>. QED BY NextPreservesIndexSafety
             DEF ProofAssumptions, Safety, IndexPreservation,
                 LegacyPreservation
<1>. QED BY <1>1, <1>2 DEF Safety, ProofAssumptions

=============================================================================
