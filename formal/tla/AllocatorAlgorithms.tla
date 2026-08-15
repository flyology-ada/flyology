---- MODULE AllocatorAlgorithms ----
EXTENDS FiniteSets, Integers, Naturals, TLC

(***************************************************************************
This bounded model extracts the guarded allocation, release, lazy-coalescing,
generation, and view-local hint transitions shared by the standalone Buddy,
Best-Fit, and TLSF arena implementations.

Blocks are physical extents.  Best-Fit and TLSF may split them at any modeled
request size.  Buddy configurations restrict sizes to aligned powers of two
and split one left path at a time, retaining each right sibling as production
does.  Best-Fit selects the smallest fitting size/address pair.  TLSF models
the exact membership relationship among physical free blocks, size-class
lists, and the class bitmap; its bounded class function is the block size.

Release publishes a free block without coalescing.  An allocation miss enters
a merge pass, then retries before reporting Exhausted.  Merge steps reduce the
number of physical blocks.  Weak fairness for guarded internal work and strong
fairness for guard acquisition establish termination for every started
operation when no owner dies.  Owner death, poisoning, address arithmetic,
native atomics, and timeout arithmetic remain outside this extraction.

FaultPolicy selects the implementation or one deliberately broken transition.
The checked broken configurations require concrete safety or temporal
counterexamples; they are not alternate supported algorithms.
***************************************************************************)

CONSTANTS Capacity, Clients, RequestSizes, BuddySizes,
          MaxOperations, MaxGeneration, Algorithm, FaultPolicy

ASSUME /\ Capacity \in Nat \ {0}
       /\ Clients # {}
       /\ RequestSizes \subseteq 1 .. Capacity
       /\ RequestSizes # {}
       /\ Capacity \in BuddySizes
       /\ BuddySizes \subseteq 1 .. Capacity
       /\ MaxOperations \in Nat \ {0}
       /\ MaxGeneration \in Nat \ {0}
       /\ Algorithm \in {"Buddy", "BestFit", "TLSF"}
       /\ FaultPolicy \in
            {"current", "no-coalesce-retry-broken",
             "stale-hint-broken", "stale-bitmap-broken",
             "stale-release-broken",
             "nonterminating-coalesce-broken"}
       /\ Algorithm = "Buddy" => RequestSizes \subseteq BuddySizes

NoClient == "no-client"
NoStart == -1
NoHandle == [start |-> NoStart, gen |-> 0]

Units == 0 .. (Capacity - 1)
Sizes == 1 .. Capacity
States == {"free", "allocated"}
Phases == {"idle", "waiting", "search", "selected", "coalescing",
            "retry", "release-validate", "finishing", "done"}
Operations == {"none", "allocate", "release"}
Results == {"none", "allocated", "released", "invalid", "exhausted",
             "generation-exhausted"}

BlockType ==
  [start : Units, size : Sizes, state : States,
   owner : Clients \cup {NoClient}, gen : 0 .. MaxGeneration]
HandleType == [start : Units, gen : 1 .. MaxGeneration]
FreeKeyType == [start : Units, size : Sizes]

VARIABLES guard, blocks, freeIndex, bins, bitmap, hints,
          phase, operation, request, targetStart, targetSize, targetHandle,
          handle, lastHandle, staleHandle, result, issued, completed,
          generation, spin

vars == <<guard, blocks, freeIndex, bins, bitmap, hints,
          phase, operation, request, targetStart, targetSize, targetHandle,
          handle, lastHandle, staleHandle, result, issued, completed,
          generation, spin>>

FreeBlock(start, size) ==
  [start |-> start, size |-> size, state |-> "free",
   owner |-> NoClient, gen |-> 0]

AllocatedBlock(start, size, client, gen) ==
  [start |-> start, size |-> size, state |-> "allocated",
   owner |-> client, gen |-> gen]

FreeBlocks(bs) == {b \in bs : b.state = "free"}
AllocatedBlocks(bs) == {b \in bs : b.state = "allocated"}
EndOf(b) == b.start + b.size
FreeKey(b) == [start |-> b.start, size |-> b.size]
IndexOf(bs) == {FreeKey(b) : b \in FreeBlocks(bs)}
BinsOf(bs) ==
  [size \in Sizes |->
     {b.start : b \in {candidate \in FreeBlocks(bs) :
                         candidate.size = size}}]
BitmapOf(bs) == {size \in Sizes : BinsOf(bs)[size] # {}}

MinimumOf(values) ==
  CHOOSE value \in values : \A other \in values : value <= other

Eligible(req, bs) == {b \in FreeBlocks(bs) : b.size >= req}

BuddyCandidate(req, bs) ==
  LET eligible == Eligible(req, bs)
      first == MinimumOf({b.start : b \in eligible})
  IN CHOOSE b \in eligible : b.start = first

BestCandidate(req, bs) ==
  LET eligible == Eligible(req, bs)
      bestSize == MinimumOf({b.size : b \in eligible})
      first == MinimumOf
        ({b.start : b \in {candidate \in eligible :
                             candidate.size = bestSize}})
  IN CHOOSE b \in eligible :
       b.size = bestSize /\ b.start = first

Candidate(req, bs) ==
  IF Algorithm = "Buddy"
  THEN BuddyCandidate(req, bs)
  ELSE BestCandidate(req, bs)

FreeBlockAt(start, bs) ==
  CHOOSE b \in FreeBlocks(bs) : b.start = start

HintIsUsable(client, req) ==
  hints[client][req] # NoStart
  /\ \E b \in FreeBlocks(blocks) :
       b.start = hints[client][req] /\ b.size = req

SelectedByHint(client) ==
  Algorithm = "Buddy" /\ hints[client][request[client]] # NoStart
  /\ (HintIsUsable(client, request[client])
      \/ FaultPolicy = "stale-hint-broken")

SelectedStart(client) ==
  IF SelectedByHint(client)
  THEN hints[client][request[client]]
  ELSE Candidate(request[client], blocks).start

SelectedSize(client) ==
  IF SelectedByHint(client)
     /\ ~HintIsUsable(client, request[client])
  THEN request[client]
  ELSE FreeBlockAt(SelectedStart(client), blocks).size

AdjacentPair(left, right) == EndOf(left) = right.start

BuddyPair(left, right) ==
  /\ AdjacentPair(left, right)
  /\ left.size = right.size
  /\ left.start % (2 * left.size) = 0

MergeablePairs(bs) ==
  {pair \in [left : FreeBlocks(bs), right : FreeBlocks(bs)] :
     IF Algorithm = "Buddy"
     THEN BuddyPair(pair.left, pair.right)
     ELSE AdjacentPair(pair.left, pair.right)}

MergedBlocks(bs, pair) ==
  (bs \ {pair.left, pair.right})
    \cup {FreeBlock(pair.left.start, pair.left.size + pair.right.size)}

InitialBlocks == {FreeBlock(0, Capacity)}

Init ==
  /\ guard = NoClient
  /\ blocks = InitialBlocks
  /\ freeIndex = IndexOf(InitialBlocks)
  /\ bins = BinsOf(InitialBlocks)
  /\ bitmap = BitmapOf(InitialBlocks)
  /\ hints = [c \in Clients |-> [size \in Sizes |-> NoStart]]
  /\ phase = [c \in Clients |-> "idle"]
  /\ operation = [c \in Clients |-> "none"]
  /\ request = [c \in Clients |-> MinimumOf(RequestSizes)]
  /\ targetStart = [c \in Clients |-> NoStart]
  /\ targetSize = [c \in Clients |-> 0]
  /\ targetHandle = [c \in Clients |-> NoHandle]
  /\ handle = [c \in Clients |-> NoHandle]
  /\ lastHandle = [c \in Clients |-> NoHandle]
  /\ staleHandle = [c \in Clients |-> NoHandle]
  /\ result = [c \in Clients |-> "none"]
  /\ issued = [c \in Clients |-> 0]
  /\ completed = [c \in Clients |-> 0]
  /\ generation = 0
  /\ spin = FALSE

PublishIndexes(newBlocks, kind) ==
  /\ freeIndex' = IndexOf(newBlocks)
  /\ bins' = BinsOf(newBlocks)
  /\ bitmap' =
       IF Algorithm = "TLSF"
          /\ FaultPolicy = "stale-bitmap-broken"
          /\ kind = "merge"
       THEN bitmap
       ELSE BitmapOf(newBlocks)

StartAllocate(client, size) ==
  /\ phase[client] = "idle"
  /\ issued[client] = completed[client]
  /\ issued[client] < MaxOperations
  /\ handle[client] = NoHandle
  /\ size \in RequestSizes
  /\ issued' = [issued EXCEPT ![client] = @ + 1]
  /\ phase' = [phase EXCEPT ![client] = "waiting"]
  /\ operation' = [operation EXCEPT ![client] = "allocate"]
  /\ request' = [request EXCEPT ![client] = size]
  /\ result' = [result EXCEPT ![client] = "none"]
  /\ targetStart' = [targetStart EXCEPT ![client] = NoStart]
  /\ targetSize' = [targetSize EXCEPT ![client] = 0]
  /\ targetHandle' = [targetHandle EXCEPT ![client] = NoHandle]
  /\ UNCHANGED <<guard, blocks, freeIndex, bins, bitmap, hints,
                  handle, lastHandle, staleHandle, completed, generation,
                  spin>>

StartRelease(client, releasedHandle) ==
  /\ phase[client] = "idle"
  /\ issued[client] = completed[client]
  /\ issued[client] < MaxOperations
  /\ releasedHandle \in
       {handle[client], lastHandle[client], staleHandle[client]} \ {NoHandle}
  /\ issued' = [issued EXCEPT ![client] = @ + 1]
  /\ phase' = [phase EXCEPT ![client] = "waiting"]
  /\ operation' = [operation EXCEPT ![client] = "release"]
  /\ targetHandle' =
       [targetHandle EXCEPT ![client] = releasedHandle]
  /\ result' = [result EXCEPT ![client] = "none"]
  /\ UNCHANGED <<guard, blocks, freeIndex, bins, bitmap, hints,
                  request, targetStart, targetSize, handle, lastHandle,
                  staleHandle, completed, generation, spin>>

Acquire(client) ==
  /\ phase[client] = "waiting"
  /\ guard = NoClient
  /\ guard' = client
  /\ phase' =
       [phase EXCEPT
          ![client] = IF operation[client] = "allocate"
                     THEN "search" ELSE "release-validate"]
  /\ UNCHANGED <<blocks, freeIndex, bins, bitmap, hints, operation,
                  request, targetStart, targetSize, targetHandle,
                  handle, lastHandle, staleHandle, result, issued, completed,
                  generation, spin>>

SelectCandidate(client) ==
  /\ phase[client] = "search"
  /\ guard = client
  /\ (Eligible(request[client], blocks) # {}
      \/ (Algorithm = "Buddy"
          /\ FaultPolicy = "stale-hint-broken"
          /\ hints[client][request[client]] # NoStart))
  /\ targetStart' =
       [targetStart EXCEPT ![client] = SelectedStart(client)]
  /\ targetSize' =
       [targetSize EXCEPT ![client] = SelectedSize(client)]
  /\ phase' = [phase EXCEPT ![client] = "selected"]
  /\ hints' =
       IF Algorithm = "Buddy"
       THEN [hints EXCEPT ![client][request[client]] = NoStart]
       ELSE hints
  /\ UNCHANGED <<guard, blocks, freeIndex, bins, bitmap, operation,
                  request, targetHandle, handle, lastHandle, staleHandle,
                  result, issued, completed, generation, spin>>

BeginCoalesce(client) ==
  /\ phase[client] = "search"
  /\ guard = client
  /\ Eligible(request[client], blocks) = {}
  /\ ~(Algorithm = "Buddy"
       /\ FaultPolicy = "stale-hint-broken"
       /\ hints[client][request[client]] # NoStart)
  /\ IF FaultPolicy = "no-coalesce-retry-broken"
        THEN /\ phase' = [phase EXCEPT ![client] = "finishing"]
             /\ result' = [result EXCEPT ![client] = "exhausted"]
        ELSE /\ phase' = [phase EXCEPT ![client] = "coalescing"]
             /\ UNCHANGED result
  /\ hints' =
       IF Algorithm = "Buddy"
       THEN [hints EXCEPT
               ![client] = [size \in Sizes |-> NoStart]]
       ELSE hints
  /\ UNCHANGED <<guard, blocks, freeIndex, bins, bitmap, operation,
                  request, targetStart, targetSize, targetHandle,
                  handle, lastHandle, staleHandle, issued, completed,
                  generation, spin>>

CoalesceStep(client) ==
  /\ phase[client] = "coalescing"
  /\ guard = client
  /\ MergeablePairs(blocks) # {}
  /\ IF FaultPolicy = "nonterminating-coalesce-broken"
        THEN /\ spin' = ~spin
             /\ UNCHANGED <<blocks, freeIndex, bins, bitmap>>
        ELSE LET pair == CHOOSE candidate \in MergeablePairs(blocks) : TRUE
                 newBlocks == MergedBlocks(blocks, pair)
             IN /\ blocks' = newBlocks
                /\ PublishIndexes(newBlocks, "merge")
                /\ UNCHANGED spin
  /\ UNCHANGED <<guard, hints, phase, operation, request,
                  targetStart, targetSize, targetHandle, handle, lastHandle,
                  staleHandle, result, issued, completed, generation>>

FinishCoalesce(client) ==
  /\ phase[client] = "coalescing"
  /\ guard = client
  /\ MergeablePairs(blocks) = {}
  /\ phase' = [phase EXCEPT ![client] = "retry"]
  /\ UNCHANGED <<guard, blocks, freeIndex, bins, bitmap, hints,
                  operation, request, targetStart, targetSize, targetHandle,
                  handle, lastHandle, staleHandle, result, issued, completed,
                  generation, spin>>

RetrySearch(client) ==
  /\ phase[client] = "retry"
  /\ guard = client
  /\ IF Eligible(request[client], blocks) # {}
        THEN LET candidate == Candidate(request[client], blocks)
             IN /\ targetStart' =
                       [targetStart EXCEPT ![client] = candidate.start]
                /\ targetSize' =
                       [targetSize EXCEPT ![client] = candidate.size]
                /\ phase' = [phase EXCEPT ![client] = "selected"]
                /\ UNCHANGED result
        ELSE /\ targetStart' = targetStart
             /\ targetSize' = targetSize
             /\ phase' = [phase EXCEPT ![client] = "finishing"]
             /\ result' = [result EXCEPT ![client] = "exhausted"]
  /\ UNCHANGED <<guard, blocks, freeIndex, bins, bitmap, hints,
                  operation, request, targetHandle, handle, lastHandle,
                  staleHandle, issued, completed, generation, spin>>

SplitBuddyCandidate(client) ==
  /\ Algorithm = "Buddy"
  /\ phase[client] = "selected"
  /\ guard = client
  /\ targetSize[client] > request[client]
  /\ \E b \in FreeBlocks(blocks) :
       b.start = targetStart[client] /\ b.size = targetSize[client]
  /\ LET old == FreeBlockAt(targetStart[client], blocks)
         half == old.size \div 2
         newBlocks ==
           (blocks \ {old})
             \cup {FreeBlock(old.start, half),
                    FreeBlock(old.start + half, half)}
     IN /\ blocks' = newBlocks
        /\ PublishIndexes(newBlocks, "split")
        /\ targetSize' = [targetSize EXCEPT ![client] = half]
  /\ UNCHANGED <<guard, hints, phase, operation, request, targetStart,
                  targetHandle, handle, lastHandle, staleHandle, result,
                  issued, completed, generation, spin>>

CommittedBlocks(client, newGeneration) ==
  LET old == FreeBlockAt(targetStart[client], blocks)
      allocated ==
        AllocatedBlock(old.start, request[client], client, newGeneration)
      withoutOld == blocks \ {old}
  IN IF Algorithm = "Buddy" \/ old.size = request[client]
     THEN withoutOld \cup {allocated}
     ELSE withoutOld \cup {allocated,
            FreeBlock(old.start + request[client],
                      old.size - request[client])}

CommitAllocation(client) ==
  /\ phase[client] = "selected"
  /\ guard = client
  /\ (Algorithm # "Buddy"
      \/ targetSize[client] = request[client])
  /\ IF generation = MaxGeneration
        THEN /\ phase' = [phase EXCEPT ![client] = "finishing"]
             /\ result' =
                  [result EXCEPT ![client] = "generation-exhausted"]
             /\ UNCHANGED <<blocks, freeIndex, bins, bitmap, handle,
                             lastHandle, staleHandle, generation>>
        ELSE LET newGeneration == generation + 1
                 staleBuddyHint ==
                   Algorithm = "Buddy"
                   /\ FaultPolicy = "stale-hint-broken"
                   /\ ~\E b \in FreeBlocks(blocks) :
                        b.start = targetStart[client]
                        /\ b.size = request[client]
                 newBlocks ==
                   IF staleBuddyHint
                   THEN blocks \cup
                     {AllocatedBlock(targetStart[client], request[client],
                                     client, newGeneration)}
                   ELSE CommittedBlocks(client, newGeneration)
                 newHandle ==
                   [start |-> targetStart[client], gen |-> newGeneration]
             IN /\ blocks' = newBlocks
                /\ PublishIndexes(newBlocks, "allocate")
                /\ generation' = newGeneration
                /\ handle' = [handle EXCEPT ![client] = newHandle]
                /\ lastHandle' =
                     [lastHandle EXCEPT ![client] = newHandle]
                /\ staleHandle' =
                     [staleHandle EXCEPT
                        ![client] = IF lastHandle[client] # NoHandle
                                   THEN lastHandle[client] ELSE @]
                /\ phase' = [phase EXCEPT ![client] = "finishing"]
                /\ result' = [result EXCEPT ![client] = "allocated"]
  /\ UNCHANGED <<guard, hints, operation, request, targetStart,
                  targetSize, targetHandle, issued, completed, spin>>

MatchingAllocation(client, releasedHandle) ==
  {b \in AllocatedBlocks(blocks) :
     b.owner = client /\ b.start = releasedHandle.start
       /\ b.gen = releasedHandle.gen}

SameStartAllocation(client, releasedHandle) ==
  {b \in AllocatedBlocks(blocks) :
     b.owner = client /\ b.start = releasedHandle.start}

ValidateRelease(client) ==
  /\ phase[client] = "release-validate"
  /\ guard = client
  /\ LET matches == MatchingAllocation(client, targetHandle[client])
     IN IF matches = {}
        THEN IF FaultPolicy = "stale-release-broken"
                /\ SameStartAllocation(client, targetHandle[client]) # {}
             THEN LET old == CHOOSE b \in
                       SameStartAllocation(client, targetHandle[client]) : TRUE
                      newBlocks ==
                        (blocks \ {old})
                          \cup {FreeBlock(old.start, old.size)}
                  IN /\ blocks' = newBlocks
                     /\ PublishIndexes(newBlocks, "release")
                     /\ hints' =
                          IF Algorithm = "Buddy"
                          THEN [hints EXCEPT
                                  ![client][old.size] = old.start]
                          ELSE hints
                     /\ phase' =
                          [phase EXCEPT ![client] = "finishing"]
                     /\ result' =
                          [result EXCEPT ![client] = "released"]
                     /\ UNCHANGED handle
             ELSE /\ phase' = [phase EXCEPT ![client] = "finishing"]
                  /\ result' = [result EXCEPT ![client] = "invalid"]
                  /\ UNCHANGED <<blocks, freeIndex, bins, bitmap, hints,
                                  handle>>
        ELSE LET old == CHOOSE b \in matches : TRUE
                 newBlocks ==
                   (blocks \ {old}) \cup {FreeBlock(old.start, old.size)}
             IN /\ blocks' = newBlocks
                /\ PublishIndexes(newBlocks, "release")
                /\ hints' =
                     IF Algorithm = "Buddy"
                     THEN [hints EXCEPT ![client][old.size] = old.start]
                     ELSE hints
                /\ handle' =
                     IF handle[client] = targetHandle[client]
                     THEN [handle EXCEPT ![client] = NoHandle]
                     ELSE handle
                /\ phase' = [phase EXCEPT ![client] = "finishing"]
                /\ result' = [result EXCEPT ![client] = "released"]
  /\ UNCHANGED <<guard, operation, request, targetStart, targetSize,
                  targetHandle, lastHandle, staleHandle, issued, completed,
                  generation, spin>>

FinishOperation(client) ==
  /\ phase[client] = "finishing"
  /\ guard = client
  /\ guard' = NoClient
  /\ completed' = [completed EXCEPT ![client] = issued[client]]
  /\ phase' = [phase EXCEPT ![client] = "done"]
  /\ UNCHANGED <<blocks, freeIndex, bins, bitmap, hints, operation,
                  request, targetStart, targetSize, targetHandle,
                  handle, lastHandle, staleHandle, result, issued,
                  generation, spin>>

ClearResult(client) ==
  /\ phase[client] = "done"
  /\ phase' = [phase EXCEPT ![client] = "idle"]
  /\ operation' = [operation EXCEPT ![client] = "none"]
  /\ UNCHANGED <<guard, blocks, freeIndex, bins, bitmap, hints,
                  request, targetStart, targetSize, targetHandle,
                  handle, lastHandle, staleHandle, result, issued, completed,
                  generation, spin>>

InternalProgress(client) ==
  SelectCandidate(client)
  \/ BeginCoalesce(client)
  \/ CoalesceStep(client)
  \/ FinishCoalesce(client)
  \/ RetrySearch(client)
  \/ SplitBuddyCandidate(client)
  \/ CommitAllocation(client)
  \/ ValidateRelease(client)
  \/ FinishOperation(client)
  \/ ClearResult(client)

Next ==
  \/ \E client \in Clients, size \in RequestSizes :
       StartAllocate(client, size)
  \/ \E client \in Clients :
       \E releasedHandle \in
            {handle[client], lastHandle[client], staleHandle[client]}
              \ {NoHandle} :
         StartRelease(client, releasedHandle)
  \/ \E client \in Clients :
       Acquire(client) \/ InternalProgress(client)

Fairness ==
  /\ \A client \in Clients : SF_vars(Acquire(client))
  /\ \A client \in Clients : WF_vars(InternalProgress(client))

Spec == Init /\ [][Next]_vars /\ Fairness

TypeOK ==
  /\ guard \in Clients \cup {NoClient}
  /\ blocks \subseteq BlockType
  /\ freeIndex \subseteq FreeKeyType
  /\ bins \in [Sizes -> SUBSET Units]
  /\ bitmap \subseteq Sizes
  /\ hints \in [Clients -> [Sizes -> Units \cup {NoStart}]]
  /\ phase \in [Clients -> Phases]
  /\ operation \in [Clients -> Operations]
  /\ request \in [Clients -> RequestSizes]
  /\ targetStart \in [Clients -> Units \cup {NoStart}]
  /\ targetSize \in [Clients -> 0 .. Capacity]
  /\ targetHandle \in [Clients -> HandleType \cup {NoHandle}]
  /\ handle \in [Clients -> HandleType \cup {NoHandle}]
  /\ lastHandle \in [Clients -> HandleType \cup {NoHandle}]
  /\ staleHandle \in [Clients -> HandleType \cup {NoHandle}]
  /\ result \in [Clients -> Results]
  /\ issued \in [Clients -> 0 .. MaxOperations]
  /\ completed \in [Clients -> 0 .. MaxOperations]
  /\ generation \in 0 .. MaxGeneration
  /\ spin \in BOOLEAN

StoredBlocksWellFormed ==
  /\ \A b \in blocks :
       /\ EndOf(b) <= Capacity
       /\ (b.state = "free" <=>
             b.owner = NoClient /\ b.gen = 0)
       /\ (b.state = "allocated" =>
             b.owner \in Clients /\ b.gen \in 1 .. generation)
  /\ \A unit \in Units :
       Cardinality({b \in blocks : b.start <= unit /\ unit < EndOf(b)}) = 1

BuddyStructure ==
  Algorithm = "Buddy" =>
    \A b \in blocks :
      b.size \in BuddySizes /\ b.start % b.size = 0

FreeIndexMatchesBlocks == freeIndex = IndexOf(blocks)

TLSFBinsMatchBlocks ==
  Algorithm = "TLSF" => bins = BinsOf(blocks)

TLSFBitmapMatchesBins ==
  Algorithm = "TLSF" => bitmap = BitmapOf(blocks)

GuardOwnsMutation ==
  \A client \in Clients :
    phase[client] \in
      {"search", "selected", "coalescing", "retry",
       "release-validate", "finishing"} => guard = client

AtMostOneGuardedOperation ==
  Cardinality
    ({client \in Clients :
       phase[client] \in
         {"search", "selected", "coalescing", "retry",
          "release-validate", "finishing"}}) <= 1

HandlesMatchAllocatedBlocks ==
  \A client \in Clients :
    handle[client] # NoHandle =>
      \E b \in AllocatedBlocks(blocks) :
        b.owner = client /\ b.start = handle[client].start
          /\ b.gen = handle[client].gen

OneAllocationPerClient ==
  \A client \in Clients :
    Cardinality({b \in AllocatedBlocks(blocks) : b.owner = client}) <= 1

NoFalseExhaustion ==
  \A client \in Clients :
    result[client] = "exhausted"
      /\ issued[client] > completed[client] =>
      /\ Eligible(request[client], blocks) = {}
      /\ MergeablePairs(blocks) = {}

OperationTermination ==
  \A client \in Clients :
    (issued[client] > completed[client]) ~>
      (issued[client] = completed[client])

=============================================================================
