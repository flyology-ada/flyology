---- MODULE SlabSpanPublication ----
EXTENDS Integers, Naturals, TLC

(***************************************************************************
Small-slab slot reuse publication extracted from Slab_Span_Kernel.

The old allocation used generation 1.  Release clears its bitmap bit, leaving
that generation stale.  Reuse writes generation 2 and republishes the bit.
With ordinary independent memory visibility and generation-first validation,
the reader may observe the new bit while retaining generation 1 and accept the
stale handle.  The corrected protocol release-publishes a 32-bit bitmap word;
validation acquire-loads that word before reading the generation.

This is a bounded visibility model, not a complete hardware memory model.  It
captures exactly the ordering obligation required by the Ada protocol.
***************************************************************************)

CONSTANT PublicationPolicy

ASSUME PublicationPolicy \in {"ordinary-broken", "release-acquire"}

VARIABLES writerPhase, memoryGeneration, memoryBit,
          visibleGeneration, visibleBit, readerPhase,
          sampledGeneration, sampledBit, staleAccepted

vars == <<writerPhase, memoryGeneration, memoryBit,
          visibleGeneration, visibleBit, readerPhase,
          sampledGeneration, sampledBit, staleAccepted>>

Init ==
  /\ writerPhase = "released"
  /\ memoryGeneration = 1
  /\ memoryBit = FALSE
  /\ visibleGeneration = 1
  /\ visibleBit = FALSE
  /\ readerPhase = "idle"
  /\ sampledGeneration = 0
  /\ sampledBit = FALSE
  /\ staleAccepted = FALSE

WriteGeneration ==
  /\ writerPhase = "released"
  /\ memoryGeneration' = 2
  /\ writerPhase' = "generation-written"
  /\ UNCHANGED <<memoryBit, visibleGeneration, visibleBit, readerPhase,
                  sampledGeneration, sampledBit, staleAccepted>>

PublishBitmap ==
  /\ writerPhase = "generation-written"
  /\ memoryBit' = TRUE
  /\ writerPhase' = "published"
  /\ UNCHANGED <<memoryGeneration, visibleGeneration, visibleBit,
                  readerPhase, sampledGeneration, sampledBit, staleAccepted>>

PropagateGeneration ==
  /\ visibleGeneration # memoryGeneration
  /\ visibleGeneration' = memoryGeneration
  /\ UNCHANGED <<writerPhase, memoryGeneration, memoryBit, visibleBit,
                  readerPhase, sampledGeneration, sampledBit, staleAccepted>>

PropagateOrdinaryBitmap ==
  /\ PublicationPolicy = "ordinary-broken"
  /\ visibleBit # memoryBit
  /\ visibleBit' = memoryBit
  /\ UNCHANGED <<writerPhase, memoryGeneration, memoryBit,
                  visibleGeneration, readerPhase, sampledGeneration,
                  sampledBit, staleAccepted>>

PropagateReleaseBitmap ==
  /\ PublicationPolicy = "release-acquire"
  /\ visibleBit # memoryBit
  /\ visibleBit' = memoryBit
  /\ visibleGeneration' = memoryGeneration
  /\ UNCHANGED <<writerPhase, memoryGeneration, memoryBit, readerPhase,
                  sampledGeneration, sampledBit, staleAccepted>>

StartValidation ==
  /\ readerPhase = "idle"
  /\ readerPhase' =
       IF PublicationPolicy = "ordinary-broken"
       THEN "read-generation" ELSE "read-bitmap"
  /\ UNCHANGED <<writerPhase, memoryGeneration, memoryBit,
                  visibleGeneration, visibleBit, sampledGeneration,
                  sampledBit, staleAccepted>>

ReadGenerationFirst ==
  /\ PublicationPolicy = "ordinary-broken"
  /\ readerPhase = "read-generation"
  /\ sampledGeneration' = visibleGeneration
  /\ readerPhase' = "read-bitmap"
  /\ UNCHANGED <<writerPhase, memoryGeneration, memoryBit,
                  visibleGeneration, visibleBit, sampledBit, staleAccepted>>

ReadBitmap ==
  /\ readerPhase = "read-bitmap"
  /\ sampledBit' = visibleBit
  /\ readerPhase' =
       IF PublicationPolicy = "ordinary-broken"
       THEN "decide" ELSE "read-generation-after-acquire"
  /\ UNCHANGED <<writerPhase, memoryGeneration, memoryBit,
                  visibleGeneration, visibleBit, sampledGeneration,
                  staleAccepted>>

ReadGenerationAfterAcquire ==
  /\ PublicationPolicy = "release-acquire"
  /\ readerPhase = "read-generation-after-acquire"
  /\ sampledGeneration' = visibleGeneration
  /\ readerPhase' = "decide"
  /\ UNCHANGED <<writerPhase, memoryGeneration, memoryBit,
                  visibleGeneration, visibleBit, sampledBit, staleAccepted>>

Decide ==
  /\ readerPhase = "decide"
  /\ staleAccepted' = sampledBit /\ sampledGeneration = 1
  /\ readerPhase' = "done"
  /\ UNCHANGED <<writerPhase, memoryGeneration, memoryBit,
                  visibleGeneration, visibleBit, sampledGeneration,
                  sampledBit>>

Next ==
  \/ WriteGeneration
  \/ PublishBitmap
  \/ PropagateGeneration
  \/ PropagateOrdinaryBitmap
  \/ PropagateReleaseBitmap
  \/ StartValidation
  \/ ReadGenerationFirst
  \/ ReadBitmap
  \/ ReadGenerationAfterAcquire
  \/ Decide

Spec == Init /\ [][Next]_vars

TypeOK ==
  /\ writerPhase \in {"released", "generation-written", "published"}
  /\ memoryGeneration \in {1, 2}
  /\ memoryBit \in BOOLEAN
  /\ visibleGeneration \in {1, 2}
  /\ visibleBit \in BOOLEAN
  /\ readerPhase \in
       {"idle", "read-generation", "read-bitmap",
        "read-generation-after-acquire", "decide", "done"}
  /\ sampledGeneration \in {0, 1, 2}
  /\ sampledBit \in BOOLEAN
  /\ staleAccepted \in BOOLEAN

NoStaleHandleAccepted == ~staleAccepted

=============================================================================
