---- MODULE SegmentRegistry ----
EXTENDS FiniteSets, Naturals

(***************************************************************************
This is a bounded state-machine extraction of
Flyology.Shared_Memory.Segments.  RegistryPolicy selects the implemented
persisted CAS guard or an intentionally broken scan-without-ownership variant.

All names have the same abstract hash.  Consequently, every successful match
in this model is attributable to the implementation's complete-name comparison
rather than to a collision-free hash assumption.

The release store that changes a slot to Initializing is represented by
Reserve.  Metadata writes before that store are one atomic abstract step
because the implemented guard prevents registry readers from observing them.
Publish and PublishFailure mirror the claim-stamped CAS transitions performed
after the guard has been released.
***************************************************************************)

CONSTANTS Clients, Names, Capacity, SegmentUnits, MaxRequest,
          MaxGeneration, RegistryPolicy

ASSUME /\ Clients # {}
       /\ Names # {}
       /\ Capacity \in Nat \ {0}
       /\ SegmentUnits \in Nat \ {0}
       /\ MaxRequest \in 1 .. SegmentUnits
       /\ MaxGeneration \in Nat \ {0}
       /\ RegistryPolicy \in {"guarded", "unlocked-broken"}

NoClient == "none"
NoName == "no-name"
NoSlot == 0
Slots == 1 .. Capacity
Lengths == 1 .. MaxRequest
SlotStates == {"free", "initializing", "ready", "failed", "removed"}
ClientPhases == {"idle", "scanning", "reserving", "dead"}
Results == {"idle", "busy", "created", "initializing", "attached",
             "failed", "length-mismatch", "exhausted",
             "generation-exhausted", "published", "failure-published",
             "abandoned"}
LiveStates == {"initializing", "ready", "failed"}

ASSUME /\ NoClient \notin Clients
       /\ NoName \notin Names

VARIABLES guard, abandonedGuard, dead,
          phase, requestName, requestLength, candidate,
          candidateLocation, candidateReserved,
          result, claimSlot, claimGeneration, handleSlot, handleGeneration,
          slotState, slotName, slotGeneration, slotLocation,
          slotReserved, slotLength, slotFailure,
          nextOffset, generation, staleHandles

vars == <<guard, abandonedGuard, dead,
          phase, requestName, requestLength, candidate,
          candidateLocation, candidateReserved,
          result, claimSlot, claimGeneration, handleSlot, handleGeneration,
          slotState, slotName, slotGeneration, slotLocation,
          slotReserved, slotLength, slotFailure,
          nextOffset, generation, staleHandles>>

ExactMatches(name) ==
  {s \in Slots : slotState[s] \in LiveStates /\ slotName[s] = name}

Reusable(length) ==
  {s \in Slots : slotState[s] = "removed" /\ slotReserved[s] >= length}

BestReusable(length) ==
  {s \in Reusable(length) :
     \A other \in Reusable(length) : slotReserved[s] <= slotReserved[other]}

FreeSlots == {s \in Slots : slotState[s] = "free"}

CandidateSlots(length) ==
  IF Reusable(length) # {} THEN BestReusable(length)
  ELSE IF FreeSlots # {} /\ nextOffset + length <= SegmentUnits
       THEN FreeSlots
       ELSE {}

Init ==
  /\ guard = NoClient
  /\ abandonedGuard = NoClient
  /\ dead = {}
  /\ phase = [c \in Clients |-> "idle"]
  /\ requestName = [c \in Clients |-> NoName]
  /\ requestLength = [c \in Clients |-> 1]
  /\ candidate = [c \in Clients |-> NoSlot]
  /\ candidateLocation = [c \in Clients |-> 0]
  /\ candidateReserved = [c \in Clients |-> 0]
  /\ result = [c \in Clients |-> "idle"]
  /\ claimSlot = [c \in Clients |-> NoSlot]
  /\ claimGeneration = [c \in Clients |-> 0]
  /\ handleSlot = [c \in Clients |-> NoSlot]
  /\ handleGeneration = [c \in Clients |-> 0]
  /\ slotState = [s \in Slots |-> "free"]
  /\ slotName = [s \in Slots |-> NoName]
  /\ slotGeneration = [s \in Slots |-> 0]
  /\ slotLocation = [s \in Slots |-> 0]
  /\ slotReserved = [s \in Slots |-> 0]
  /\ slotLength = [s \in Slots |-> 0]
  /\ slotFailure = [s \in Slots |-> 0]
  /\ nextOffset = 0
  /\ generation = 0
  /\ staleHandles = {}

StartRequest(c, name, length) ==
  /\ c \notin dead
  /\ phase[c] = "idle"
  /\ result[c] = "idle"
  /\ claimSlot[c] = NoSlot
  /\ name \in Names
  /\ length \in Lengths
  /\ requestName' = [requestName EXCEPT ![c] = name]
  /\ requestLength' = [requestLength EXCEPT ![c] = length]
  /\ IF RegistryPolicy = "guarded" /\ guard # NoClient
        THEN /\ result' = [result EXCEPT ![c] = "busy"]
             /\ UNCHANGED <<guard, phase>>
        ELSE /\ phase' = [phase EXCEPT ![c] = "scanning"]
             /\ result' = result
             /\ guard' = IF RegistryPolicy = "guarded" THEN c ELSE guard
  /\ UNCHANGED <<abandonedGuard, dead, candidate,
                  candidateLocation, candidateReserved,
                  claimSlot, claimGeneration, handleSlot, handleGeneration,
                  slotState, slotName, slotGeneration, slotLocation,
                  slotReserved, slotLength, slotFailure,
                  nextOffset, generation, staleHandles>>

ReturnExisting(c, slot) ==
  /\ phase[c] = "scanning"
  /\ RegistryPolicy = "unlocked-broken" \/ guard = c
  /\ slot \in ExactMatches(requestName[c])
  /\ handleSlot' = [handleSlot EXCEPT ![c] = slot]
  /\ handleGeneration' =
       [handleGeneration EXCEPT ![c] = slotGeneration[slot]]
  /\ result' =
       [result EXCEPT
          ![c] = IF slotState[slot] = "initializing" THEN "initializing"
                  ELSE IF slotState[slot] = "failed" THEN "failed"
                  ELSE IF slotLength[slot] # requestLength[c]
                       THEN "length-mismatch"
                       ELSE "attached"]
  /\ phase' = [phase EXCEPT ![c] = "idle"]
  /\ guard' = IF RegistryPolicy = "guarded" THEN NoClient ELSE guard
  /\ UNCHANGED <<abandonedGuard, dead, requestName, requestLength,
                  candidate, candidateLocation, candidateReserved,
                  claimSlot, claimGeneration,
                  slotState, slotName, slotGeneration, slotLocation,
                  slotReserved, slotLength, slotFailure,
                  nextOffset, generation, staleHandles>>

ChooseCandidate(c, slot) ==
  /\ phase[c] = "scanning"
  /\ RegistryPolicy = "unlocked-broken" \/ guard = c
  /\ generation < MaxGeneration
  /\ ExactMatches(requestName[c]) = {}
  /\ slot \in CandidateSlots(requestLength[c])
  /\ candidate' = [candidate EXCEPT ![c] = slot]
  /\ candidateLocation' =
       [candidateLocation EXCEPT
          ![c] = IF slotState[slot] = "removed"
                 THEN slotLocation[slot] ELSE nextOffset]
  /\ candidateReserved' =
       [candidateReserved EXCEPT
          ![c] = IF slotState[slot] = "removed"
                 THEN slotReserved[slot] ELSE requestLength[c]]
  /\ phase' = [phase EXCEPT ![c] = "reserving"]
  /\ UNCHANGED <<guard, abandonedGuard, dead,
                  requestName, requestLength, result,
                  claimSlot, claimGeneration, handleSlot, handleGeneration,
                  slotState, slotName, slotGeneration, slotLocation,
                  slotReserved, slotLength, slotFailure,
                  nextOffset, generation, staleHandles>>

ReturnExhausted(c) ==
  /\ phase[c] = "scanning"
  /\ RegistryPolicy = "unlocked-broken" \/ guard = c
  /\ generation < MaxGeneration
  /\ ExactMatches(requestName[c]) = {}
  /\ CandidateSlots(requestLength[c]) = {}
  /\ result' = [result EXCEPT ![c] = "exhausted"]
  /\ phase' = [phase EXCEPT ![c] = "idle"]
  /\ guard' = IF RegistryPolicy = "guarded" THEN NoClient ELSE guard
  /\ UNCHANGED <<abandonedGuard, dead, requestName, requestLength,
                  candidate, candidateLocation, candidateReserved,
                  claimSlot, claimGeneration, handleSlot, handleGeneration,
                  slotState, slotName, slotGeneration, slotLocation,
                  slotReserved, slotLength, slotFailure,
                  nextOffset, generation, staleHandles>>

ReturnGenerationExhausted(c) ==
  /\ phase[c] = "scanning"
  /\ RegistryPolicy = "unlocked-broken" \/ guard = c
  /\ ExactMatches(requestName[c]) = {}
  /\ generation = MaxGeneration
  /\ result' = [result EXCEPT ![c] = "generation-exhausted"]
  /\ phase' = [phase EXCEPT ![c] = "idle"]
  /\ guard' = IF RegistryPolicy = "guarded" THEN NoClient ELSE guard
  /\ UNCHANGED <<abandonedGuard, dead, requestName, requestLength,
                  candidate, candidateLocation, candidateReserved,
                  claimSlot, claimGeneration, handleSlot, handleGeneration,
                  slotState, slotName, slotGeneration, slotLocation,
                  slotReserved, slotLength, slotFailure,
                  nextOffset, generation, staleHandles>>

Reserve(c) ==
  LET slot == candidate[c] IN
    /\ phase[c] = "reserving"
    /\ slot \in Slots
    /\ generation < MaxGeneration
    /\ RegistryPolicy = "unlocked-broken"
         \/ (guard = c /\ slotState[slot] \in {"free", "removed"})
    /\ slotState' = [slotState EXCEPT ![slot] = "initializing"]
    /\ slotName' = [slotName EXCEPT ![slot] = requestName[c]]
    /\ slotGeneration' = [slotGeneration EXCEPT ![slot] = generation + 1]
    /\ slotLocation' =
         [slotLocation EXCEPT ![slot] = candidateLocation[c]]
    /\ slotReserved' =
         [slotReserved EXCEPT ![slot] = candidateReserved[c]]
    /\ slotLength' = [slotLength EXCEPT ![slot] = requestLength[c]]
    /\ slotFailure' = [slotFailure EXCEPT ![slot] = 0]
    /\ nextOffset' =
         IF candidateLocation[c] = nextOffset
         THEN candidateLocation[c] + candidateReserved[c]
         ELSE nextOffset
    /\ generation' = generation + 1
    /\ claimSlot' = [claimSlot EXCEPT ![c] = slot]
    /\ claimGeneration' =
         [claimGeneration EXCEPT ![c] = generation + 1]
    /\ handleSlot' = [handleSlot EXCEPT ![c] = slot]
    /\ handleGeneration' =
         [handleGeneration EXCEPT ![c] = generation + 1]
    /\ result' = [result EXCEPT ![c] = "created"]
    /\ phase' = [phase EXCEPT ![c] = "idle"]
    /\ guard' = IF RegistryPolicy = "guarded" THEN NoClient ELSE guard
    /\ UNCHANGED <<abandonedGuard, dead, requestName, requestLength,
                    candidate, candidateLocation, candidateReserved,
                    staleHandles>>

Publish(c) ==
  LET slot == claimSlot[c] IN
    /\ c \notin dead
    /\ slot \in Slots
    /\ slotState[slot] = "initializing"
    /\ slotGeneration[slot] = claimGeneration[c]
    /\ slotState' = [slotState EXCEPT ![slot] = "ready"]
    /\ claimSlot' = [claimSlot EXCEPT ![c] = NoSlot]
    /\ claimGeneration' = [claimGeneration EXCEPT ![c] = 0]
    /\ result' = [result EXCEPT ![c] = "published"]
    /\ UNCHANGED <<guard, abandonedGuard, dead,
                    phase, requestName, requestLength, candidate,
                    candidateLocation, candidateReserved,
                    handleSlot, handleGeneration, slotName, slotGeneration,
                    slotLocation, slotReserved, slotLength, slotFailure,
                    nextOffset, generation, staleHandles>>

PublishFailure(c) ==
  LET slot == claimSlot[c] IN
    /\ c \notin dead
    /\ slot \in Slots
    /\ slotState[slot] = "initializing"
    /\ slotGeneration[slot] = claimGeneration[c]
    /\ slotState' = [slotState EXCEPT ![slot] = "failed"]
    /\ slotFailure' = [slotFailure EXCEPT ![slot] = 1]
    /\ claimSlot' = [claimSlot EXCEPT ![c] = NoSlot]
    /\ claimGeneration' = [claimGeneration EXCEPT ![c] = 0]
    /\ result' = [result EXCEPT ![c] = "failure-published"]
    /\ UNCHANGED <<guard, abandonedGuard, dead,
                    phase, requestName, requestLength, candidate,
                    candidateLocation, candidateReserved,
                    handleSlot, handleGeneration, slotName, slotGeneration,
                    slotLocation, slotReserved, slotLength,
                    nextOffset, generation, staleHandles>>

Remove(name, slot) ==
  /\ name \in Names
  /\ slot \in ExactMatches(name)
  /\ slotState[slot] \in {"ready", "failed"}
  /\ RegistryPolicy = "unlocked-broken" \/ guard = NoClient
  /\ slotState' = [slotState EXCEPT ![slot] = "removed"]
  /\ staleHandles' =
       staleHandles \cup {[slot |-> slot, gen |-> slotGeneration[slot]]}
  /\ UNCHANGED <<guard, abandonedGuard, dead,
                  phase, requestName, requestLength, candidate,
                  candidateLocation, candidateReserved,
                  result, claimSlot, claimGeneration,
                  handleSlot, handleGeneration,
                  slotName, slotGeneration, slotLocation,
                  slotReserved, slotLength, slotFailure,
                  nextOffset, generation>>

ResetClient(c) ==
  /\ c \notin dead
  /\ phase[c] = "idle"
  /\ result[c] # "idle"
  /\ claimSlot[c] = NoSlot
  /\ result' = [result EXCEPT ![c] = "idle"]
  /\ requestName' = [requestName EXCEPT ![c] = NoName]
  /\ handleSlot' = [handleSlot EXCEPT ![c] = NoSlot]
  /\ handleGeneration' = [handleGeneration EXCEPT ![c] = 0]
  /\ UNCHANGED <<guard, abandonedGuard, dead, phase, requestLength,
                  candidate, candidateLocation, candidateReserved,
                  claimSlot, claimGeneration,
                  slotState, slotName, slotGeneration, slotLocation,
                  slotReserved, slotLength, slotFailure,
                  nextOffset, generation, staleHandles>>

CrashWithGuard(c) ==
  /\ RegistryPolicy = "guarded"
  /\ guard = c
  /\ phase[c] \in {"scanning", "reserving"}
  /\ dead' = dead \cup {c}
  /\ phase' = [phase EXCEPT ![c] = "dead"]
  /\ result' = [result EXCEPT ![c] = "abandoned"]
  /\ abandonedGuard' = c
  /\ UNCHANGED <<guard, requestName, requestLength, candidate,
                  candidateLocation, candidateReserved,
                  claimSlot, claimGeneration, handleSlot, handleGeneration,
                  slotState, slotName, slotGeneration, slotLocation,
                  slotReserved, slotLength, slotFailure,
                  nextOffset, generation, staleHandles>>

CrashCreator(c) ==
  /\ c \notin dead
  /\ claimSlot[c] # NoSlot
  /\ dead' = dead \cup {c}
  /\ phase' = [phase EXCEPT ![c] = "dead"]
  /\ result' = [result EXCEPT ![c] = "abandoned"]
  /\ claimSlot' = [claimSlot EXCEPT ![c] = NoSlot]
  /\ claimGeneration' = [claimGeneration EXCEPT ![c] = 0]
  /\ UNCHANGED <<guard, abandonedGuard, requestName, requestLength,
                  candidate, candidateLocation, candidateReserved,
                  handleSlot, handleGeneration,
                  slotState, slotName, slotGeneration, slotLocation,
                  slotReserved, slotLength, slotFailure,
                  nextOffset, generation, staleHandles>>

Next ==
  \/ \E c \in Clients, name \in Names, length \in Lengths :
       StartRequest(c, name, length)
  \/ \E c \in Clients, slot \in Slots :
       ReturnExisting(c, slot) \/ ChooseCandidate(c, slot)
  \/ \E c \in Clients :
       ReturnExhausted(c) \/ ReturnGenerationExhausted(c)
         \/ Reserve(c) \/ Publish(c)
         \/ PublishFailure(c) \/ ResetClient(c)
         \/ CrashWithGuard(c) \/ CrashCreator(c)
  \/ \E name \in Names, slot \in Slots : Remove(name, slot)

Spec == Init /\ [][Next]_vars

TypeOK ==
  /\ guard \in Clients \cup {NoClient}
  /\ abandonedGuard \in Clients \cup {NoClient}
  /\ dead \subseteq Clients
  /\ phase \in [Clients -> ClientPhases]
  /\ requestName \in [Clients -> Names \cup {NoName}]
  /\ requestLength \in [Clients -> Lengths]
  /\ candidate \in [Clients -> Slots \cup {NoSlot}]
  /\ candidateLocation \in [Clients -> 0 .. SegmentUnits]
  /\ candidateReserved \in [Clients -> 0 .. MaxRequest]
  /\ result \in [Clients -> Results]
  /\ claimSlot \in [Clients -> Slots \cup {NoSlot}]
  /\ claimGeneration \in [Clients -> 0 .. MaxGeneration]
  /\ handleSlot \in [Clients -> Slots \cup {NoSlot}]
  /\ handleGeneration \in [Clients -> 0 .. MaxGeneration]
  /\ slotState \in [Slots -> SlotStates]
  /\ slotName \in [Slots -> Names \cup {NoName}]
  /\ slotGeneration \in [Slots -> 0 .. MaxGeneration]
  /\ slotLocation \in [Slots -> 0 .. SegmentUnits]
  /\ slotReserved \in [Slots -> 0 .. SegmentUnits]
  /\ slotLength \in [Slots -> 0 .. MaxRequest]
  /\ slotFailure \in [Slots -> 0 .. 1]
  /\ nextOffset \in 0 .. SegmentUnits
  /\ generation \in 0 .. MaxGeneration
  /\ staleHandles \subseteq
       [slot : Slots, gen : 1 .. MaxGeneration]

AtMostOneLiveExactName ==
  \A s1, s2 \in Slots :
    (slotState[s1] \in LiveStates /\ slotState[s2] \in LiveStates
      /\ slotName[s1] = slotName[s2]) => s1 = s2

ClaimsMatchInitializingSlot ==
  \A c \in Clients :
    claimSlot[c] # NoSlot =>
      /\ slotState[claimSlot[c]] = "initializing"
      /\ slotGeneration[claimSlot[c]] = claimGeneration[c]

AtMostOneCreatorPerClaim ==
  \A c1, c2 \in Clients :
    (claimSlot[c1] # NoSlot
      /\ claimSlot[c1] = claimSlot[c2]
      /\ claimGeneration[c1] = claimGeneration[c2]) => c1 = c2

ReadyOrFailedHasNoCreator ==
  \A s \in Slots : slotState[s] \in {"ready", "failed"} =>
    \A c \in Clients :
      claimSlot[c] # s \/ claimGeneration[c] # slotGeneration[s]

ReturnedHandlesUseExactNames ==
  \A c \in Clients :
    result[c] \in {"created", "initializing", "attached", "failed",
                    "length-mismatch", "published", "failure-published"} =>
      /\ handleSlot[c] \in Slots
      /\ (handleGeneration[c] = slotGeneration[handleSlot[c]] =>
            slotName[handleSlot[c]] = requestName[c])

FailedSlotsHaveCodes ==
  \A s \in Slots : slotState[s] = "failed" => slotFailure[s] # 0

ReservationMetadataValid ==
  \A s \in Slots : slotState[s] # "free" =>
    /\ slotName[s] \in Names
    /\ slotGeneration[s] \in 1 .. generation
    /\ slotLength[s] \in Lengths
    /\ slotReserved[s] >= slotLength[s]
    /\ slotLocation[s] + slotReserved[s] <= SegmentUnits
    /\ slotLocation[s] + slotReserved[s] <= nextOffset

ReservationsDoNotOverlap ==
  \A s1, s2 \in Slots :
    (s1 # s2 /\ slotState[s1] # "free" /\ slotState[s2] # "free") =>
      slotLocation[s1] + slotReserved[s1] <= slotLocation[s2]
        \/ slotLocation[s2] + slotReserved[s2] <= slotLocation[s1]

StaleHandlesNeverResolve ==
  \A handle \in staleHandles :
    slotState[handle.slot] # "ready"
      \/ slotGeneration[handle.slot] # handle.gen

AbandonedGuardIsNeverStolen ==
  abandonedGuard = NoClient \/ guard = abandonedGuard

GuardOwnerHasAnActiveOrAbandonedRequest ==
  guard # NoClient => phase[guard] \in {"scanning", "reserving", "dead"}

IdleClientDoesNotOwnGuard ==
  RegistryPolicy = "guarded" =>
    \A c \in Clients : phase[c] = "idle" => guard # c

=============================================================================
