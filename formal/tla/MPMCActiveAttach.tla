---- MODULE MPMCActiveAttach ----
EXTENDS Integers, Naturals

(***************************************************************************
The bounded model mirrors Flyology.Data_Structures.Rings.MPMC:

* ProducerClaim is the enqueue-position CAS.
* ProducerPublish is the release store of position + 1 to the slot sequence.
* ConsumerClaim is the dequeue-position CAS.
* ConsumerRelease is the release store of position + Capacity.
* Attach performs either the current immutable-only validation or the removed
  mutable sequence scan, selected by AttachPolicy.

Payload copying and observation are represented by the interval between claim
and publication/release.  The model deliberately permits several outstanding
producer and consumer claims, just as the implementation does.
***************************************************************************)

CONSTANTS Capacity, MaxPosition, Producers, Consumers, Attachers, AttachPolicy

ASSUME /\ Capacity \in Nat \ {0}
       /\ MaxPosition \in Nat \ {0}
       /\ Producers # {}
       /\ Consumers # {}
       /\ Attachers # {}
       /\ AttachPolicy \in {"immutable-only", "legacy-deep-scan"}

NoClaim == -1
Slots == 0 .. (Capacity - 1)
Slot(position) == position % Capacity

VARIABLES enqueue, dequeue, sequence,
          producerClaim, consumerClaim, attachResult

vars == <<enqueue, dequeue, sequence,
          producerClaim, consumerClaim, attachResult>>

ExpectedSequence(offset) ==
  LET position == dequeue + offset IN
    IF offset < enqueue - dequeue THEN position + 1 ELSE position

DeepValid ==
  /\ dequeue <= enqueue
  /\ enqueue - dequeue <= Capacity
  /\ \A offset \in 0 .. (Capacity - 1) :
       sequence[Slot(dequeue + offset)] = ExpectedSequence(offset)

NoOutstandingClaims ==
  /\ \A p \in Producers : producerClaim[p] = NoClaim
  /\ \A c \in Consumers : consumerClaim[c] = NoClaim

Init ==
  /\ enqueue = 0
  /\ dequeue = 0
  /\ sequence = [slot \in Slots |-> slot]
  /\ producerClaim = [p \in Producers |-> NoClaim]
  /\ consumerClaim = [c \in Consumers |-> NoClaim]
  /\ attachResult = [a \in Attachers |-> "idle"]

ProducerClaim(p) ==
  /\ producerClaim[p] = NoClaim
  /\ enqueue < MaxPosition
  /\ enqueue - dequeue < Capacity
  /\ sequence[Slot(enqueue)] = enqueue
  /\ producerClaim' = [producerClaim EXCEPT ![p] = enqueue]
  /\ enqueue' = enqueue + 1
  /\ UNCHANGED <<dequeue, sequence, consumerClaim, attachResult>>

ProducerPublish(p) ==
  LET position == producerClaim[p] IN
    /\ position # NoClaim
    /\ sequence' = [sequence EXCEPT ![Slot(position)] = position + 1]
    /\ producerClaim' = [producerClaim EXCEPT ![p] = NoClaim]
    /\ UNCHANGED <<enqueue, dequeue, consumerClaim, attachResult>>

ConsumerClaim(c) ==
  /\ consumerClaim[c] = NoClaim
  /\ dequeue < MaxPosition
  /\ sequence[Slot(dequeue)] = dequeue + 1
  /\ consumerClaim' = [consumerClaim EXCEPT ![c] = dequeue]
  /\ dequeue' = dequeue + 1
  /\ UNCHANGED <<enqueue, sequence, producerClaim, attachResult>>

ConsumerRelease(c) ==
  LET position == consumerClaim[c] IN
    /\ position # NoClaim
    /\ sequence' =
         [sequence EXCEPT ![Slot(position)] = position + Capacity]
    /\ consumerClaim' = [consumerClaim EXCEPT ![c] = NoClaim]
    /\ UNCHANGED <<enqueue, dequeue, producerClaim, attachResult>>

Attach(a) ==
  /\ attachResult[a] = "idle"
  /\ attachResult' =
       [attachResult EXCEPT
          ![a] = IF AttachPolicy = "immutable-only" \/ DeepValid
                 THEN "attached"
                 ELSE "rejected"]
  /\ UNCHANGED <<enqueue, dequeue, sequence,
                  producerClaim, consumerClaim>>

Next ==
  \/ \E p \in Producers : ProducerClaim(p) \/ ProducerPublish(p)
  \/ \E c \in Consumers : ConsumerClaim(c) \/ ConsumerRelease(c)
  \/ \E a \in Attachers : Attach(a)

Spec == Init /\ [][Next]_vars

TypeOK ==
  /\ enqueue \in 0 .. MaxPosition
  /\ dequeue \in 0 .. MaxPosition
  /\ sequence \in [Slots -> 0 .. (MaxPosition + Capacity)]
  /\ producerClaim \in [Producers -> NoClaim .. MaxPosition]
  /\ consumerClaim \in [Consumers -> NoClaim .. MaxPosition]
  /\ attachResult \in [Attachers -> {"idle", "attached", "rejected"}]

OccupancyBound == dequeue <= enqueue /\ enqueue - dequeue <= Capacity

UniqueProducerClaims ==
  \A p1, p2 \in Producers :
    (producerClaim[p1] # NoClaim /\ producerClaim[p1] = producerClaim[p2])
      => p1 = p2

UniqueConsumerClaims ==
  \A c1, c2 \in Consumers :
    (consumerClaim[c1] # NoClaim /\ consumerClaim[c1] = consumerClaim[c2])
      => c1 = c2

DisjointClaims ==
  \A p \in Producers, c \in Consumers :
    producerClaim[p] = NoClaim \/ consumerClaim[c] = NoClaim
      \/ producerClaim[p] # consumerClaim[c]

QuiescentDeepValidation == NoOutstandingClaims => DeepValid

NoFalseAttachRejection ==
  \A a \in Attachers : attachResult[a] # "rejected"

=============================================================================
