---- MODULE SlabSpanAllocator ----
EXTENDS FiniteSets, Integers, Naturals, TLC

(***************************************************************************
Bounded extraction of Slab_Span_Kernel's guarded metadata transitions.

Each modeled run has two minimum-size units.  A request of one unit uses a
bitmap slot in a small slab; requests of two or four units reserve contiguous
runs.  Empty slabs stay classed after release.  A miss reclaims every empty
slab and retries before Exhausted, matching Allocate_Unlocked.  Large release
publishes every run in its span free immediately.  Handles name a starting
unit and generation.  One guard owner performs every metadata transition.

Native address validation, byte offsets, timeout arithmetic, poisoning after
an exception, and payload copies remain outside this state extraction.  The
no-reclaim-retry and nonterminating-retry policies are deliberately broken and
must produce the counterexamples required by check-tla.sh.
***************************************************************************)

CONSTANTS RunCount, SlotsPerRun, Requests, MaxGeneration, MaxOperations,
          FaultPolicy

ASSUME /\ RunCount \in Nat \ {0}
       /\ SlotsPerRun \in Nat \ {0}
       /\ Requests \subseteq {1, SlotsPerRun, RunCount * SlotsPerRun}
       /\ Requests # {}
       /\ MaxGeneration \in Nat \ {0}
       /\ MaxOperations \in Nat \ {0}
       /\ FaultPolicy \in
            {"current", "no-reclaim-retry-broken",
             "nonterminating-retry-broken"}

RunIds == 0 .. (RunCount - 1)
SlotIds == 0 .. (SlotsPerRun - 1)
Units == 0 .. (RunCount * SlotsPerRun - 1)
Kinds == {"free", "small", "large-head", "large-tail"}
NoRun == -1
NoHandle == [unit |-> -1, gen |-> 0]
HandleType == [unit : Units, gen : 1 .. MaxGeneration]
RunType ==
  [kind : Kinds, bitmap : SUBSET SlotIds, span : 0 .. RunCount,
   head : RunIds \cup {NoRun}]

FreeRun == [kind |-> "free", bitmap |-> {}, span |-> 0, head |-> NoRun]
EmptySmall == [kind |-> "small", bitmap |-> {}, span |-> 0,
               head |-> NoRun]

VARIABLES guard, runs, phase, request, result, generation, generations,
          liveHandles, staleHandles, targetHandle, operations, spin

vars == <<guard, runs, phase, request, result, generation, generations,
          liveHandles, staleHandles, targetHandle, operations, spin>>

Init ==
  /\ guard = FALSE
  /\ runs = [r \in RunIds |-> FreeRun]
  /\ phase = "idle"
  /\ request = 1
  /\ result = "none"
  /\ generation = 0
  /\ generations = [u \in Units |-> 0]
  /\ liveHandles = {}
  /\ staleHandles = {}
  /\ targetHandle = NoHandle
  /\ operations = 0
  /\ spin = FALSE

PartialRuns ==
  {r \in RunIds : runs[r].kind = "small"
                    /\ Cardinality(runs[r].bitmap) < SlotsPerRun}
FreeRuns == {r \in RunIds : runs[r].kind = "free"}
EmptySlabs ==
  {r \in RunIds : runs[r].kind = "small" /\ runs[r].bitmap = {}}

Minimum(values) ==
  CHOOSE value \in values : \A other \in values : value <= other

NeededRuns(size) == (size + SlotsPerRun - 1) \div SlotsPerRun
SpanStarts(size, state) ==
  LET needed == NeededRuns(size)
  IN {start \in 0 .. (RunCount - needed) :
        \A r \in start .. (start + needed - 1) :
          state[r].kind = "free"}

Reclaimed(state) ==
  [r \in RunIds |->
    IF state[r].kind = "small" /\ state[r].bitmap = {}
    THEN FreeRun ELSE state[r]]

LogicalFree(state, r) ==
  state[r].kind = "free"
  \/ (state[r].kind = "small" /\ state[r].bitmap = {})

CanAllocateAfterReclaim(size) ==
  IF size = 1
  THEN PartialRuns # {} \/ FreeRuns # {} \/ EmptySlabs # {}
  ELSE LET needed == NeededRuns(size)
       IN \E start \in 0 .. (RunCount - needed) :
            \A r \in start .. (start + needed - 1) :
              LogicalFree(runs, r)

StartAllocate(size) ==
  /\ phase = "idle"
  /\ operations < MaxOperations
  /\ size \in Requests
  /\ guard' = TRUE
  /\ phase' = "search"
  /\ request' = size
  /\ result' = "none"
  /\ operations' = operations + 1
  /\ UNCHANGED <<runs, generation, generations, liveHandles,
                  staleHandles, targetHandle, spin>>

SmallCandidate ==
  IF PartialRuns # {} THEN Minimum(PartialRuns)
  ELSE Minimum(FreeRuns)

AllocateSmall ==
  /\ phase \in {"search", "retry"}
  /\ guard
  /\ request = 1
  /\ PartialRuns # {} \/ FreeRuns # {}
  /\ generation < MaxGeneration
  /\ LET selected == SmallCandidate
         prior == IF runs[selected].kind = "free"
                  THEN EmptySmall ELSE runs[selected]
         freeSlots == SlotIds \ prior.bitmap
         slot == Minimum(freeSlots)
         unit == selected * SlotsPerRun + slot
         nextGeneration == generation + 1
         nextHandle == [unit |-> unit, gen |-> nextGeneration]
     IN /\ runs' = [runs EXCEPT
                       ![selected] =
                         [prior EXCEPT !.bitmap = @ \cup {slot}]]
        /\ generations' =
             [generations EXCEPT ![unit] = nextGeneration]
        /\ liveHandles' = liveHandles \cup {nextHandle}
  /\ generation' = generation + 1
  /\ phase' = "finishing"
  /\ result' = "allocated"
  /\ UNCHANGED <<guard, request, staleHandles, targetHandle,
                  operations, spin>>

AllocateLarge ==
  /\ phase \in {"search", "retry"}
  /\ guard
  /\ request > 1
  /\ SpanStarts(request, runs) # {}
  /\ generation < MaxGeneration
  /\ LET selected == Minimum(SpanStarts(request, runs))
         needed == NeededRuns(request)
         nextGeneration == generation + 1
         unit == selected * SlotsPerRun
         nextHandle == [unit |-> unit, gen |-> nextGeneration]
         nextRuns ==
           [r \in RunIds |->
             IF r = selected
             THEN [kind |-> "large-head", bitmap |-> {},
                   span |-> needed, head |-> NoRun]
             ELSE IF r \in (selected + 1) .. (selected + needed - 1)
             THEN [kind |-> "large-tail", bitmap |-> {},
                   span |-> 0, head |-> selected]
             ELSE runs[r]]
     IN /\ runs' = nextRuns
        /\ generations' =
             [generations EXCEPT ![unit] = nextGeneration]
        /\ liveHandles' = liveHandles \cup {nextHandle}
  /\ generation' = generation + 1
  /\ phase' = "finishing"
  /\ result' = "allocated"
  /\ UNCHANGED <<guard, request, staleHandles, targetHandle,
                  operations, spin>>

Misses ==
  (request = 1 /\ PartialRuns = {} /\ FreeRuns = {})
  \/ (request > 1 /\ SpanStarts(request, runs) = {})

BeginReclaim ==
  /\ phase = "search"
  /\ guard
  /\ Misses
  /\ EmptySlabs # {}
  /\ FaultPolicy # "no-reclaim-retry-broken"
  /\ runs' = Reclaimed(runs)
  /\ phase' = "retry"
  /\ UNCHANGED <<guard, request, result, generation, generations,
                  liveHandles, staleHandles, targetHandle, operations, spin>>

BrokenExhaustion ==
  /\ phase = "search"
  /\ guard
  /\ Misses
  /\ FaultPolicy = "no-reclaim-retry-broken"
  /\ phase' = "finishing"
  /\ result' = "exhausted"
  /\ UNCHANGED <<guard, runs, request, generation, generations,
                  liveHandles, staleHandles, targetHandle, operations, spin>>

GenuineExhaustion ==
  /\ phase \in {"search", "retry"}
  /\ guard
  /\ Misses
  /\ EmptySlabs = {}
  /\ phase' = "finishing"
  /\ result' = "exhausted"
  /\ UNCHANGED <<guard, runs, request, generation, generations,
                  liveHandles, staleHandles, targetHandle, operations, spin>>

SpinRetry ==
  /\ phase = "retry"
  /\ guard
  /\ FaultPolicy = "nonterminating-retry-broken"
  /\ spin' = ~spin
  /\ UNCHANGED <<guard, runs, phase, request, result, generation,
                  generations, liveHandles, staleHandles, targetHandle,
                  operations>>

StartRelease(handle) ==
  /\ phase = "idle"
  /\ operations < MaxOperations
  /\ handle \in liveHandles \cup staleHandles
  /\ guard' = TRUE
  /\ phase' = "release"
  /\ targetHandle' = handle
  /\ result' = "none"
  /\ operations' = operations + 1
  /\ UNCHANGED <<runs, request, generation, generations, liveHandles,
                  staleHandles, spin>>

InvalidRelease ==
  /\ phase = "release"
  /\ guard
  /\ targetHandle \notin liveHandles
  /\ phase' = "finishing"
  /\ result' = "invalid"
  /\ UNCHANGED <<guard, runs, request, generation, generations,
                  liveHandles, staleHandles, targetHandle, operations, spin>>

ReleaseLive ==
  /\ phase = "release"
  /\ guard
  /\ targetHandle \in liveHandles
  /\ LET unit == targetHandle.unit
         run == unit \div SlotsPerRun
         slot == unit % SlotsPerRun
         descriptor == runs[run]
         nextRuns ==
           IF descriptor.kind = "small"
           THEN [runs EXCEPT ![run].bitmap = @ \ {slot}]
           ELSE [r \in RunIds |->
                  IF r \in run .. (run + descriptor.span - 1)
                  THEN FreeRun ELSE runs[r]]
     IN runs' = nextRuns
  /\ liveHandles' = liveHandles \ {targetHandle}
  /\ staleHandles' = staleHandles \cup {targetHandle}
  /\ phase' = "finishing"
  /\ result' = "released"
  /\ UNCHANGED <<guard, request, generation, generations, targetHandle,
                  operations, spin>>

Finish ==
  /\ phase = "finishing"
  /\ guard
  /\ guard' = FALSE
  /\ phase' = "idle"
  /\ targetHandle' = NoHandle
  /\ UNCHANGED <<runs, request, result, generation, generations,
                  liveHandles, staleHandles, operations, spin>>

Next ==
  \/ \E size \in Requests : StartAllocate(size)
  \/ AllocateSmall
  \/ AllocateLarge
  \/ BeginReclaim
  \/ BrokenExhaustion
  \/ GenuineExhaustion
  \/ SpinRetry
  \/ \E handle \in liveHandles \cup staleHandles : StartRelease(handle)
  \/ InvalidRelease
  \/ ReleaseLive
  \/ Finish

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

TypeOK ==
  /\ guard \in BOOLEAN
  /\ runs \in [RunIds -> RunType]
  /\ phase \in {"idle", "search", "retry", "release", "finishing"}
  /\ request \in Requests
  /\ result \in {"none", "allocated", "released", "invalid", "exhausted"}
  /\ generation \in 0 .. MaxGeneration
  /\ generations \in [Units -> 0 .. MaxGeneration]
  /\ liveHandles \subseteq HandleType
  /\ staleHandles \subseteq HandleType
  /\ targetHandle \in HandleType \cup {NoHandle}
  /\ operations \in 0 .. MaxOperations
  /\ spin \in BOOLEAN

RunsWellFormed ==
  /\ \A r \in RunIds :
       CASE runs[r].kind = "free" -> runs[r] = FreeRun
         [] runs[r].kind = "small" ->
              /\ runs[r].span = 0 /\ runs[r].head = NoRun
         [] runs[r].kind = "large-head" ->
              /\ runs[r].bitmap = {} /\ runs[r].head = NoRun
              /\ runs[r].span \in 1 .. (RunCount - r)
              /\ \A tail \in (r + 1) .. (r + runs[r].span - 1) :
                   runs[tail].kind = "large-tail"
                   /\ runs[tail].head = r
         [] runs[r].kind = "large-tail" ->
              /\ runs[r].bitmap = {} /\ runs[r].span = 0
              /\ runs[r].head < r
              /\ runs[runs[r].head].kind = "large-head"
              /\ r < runs[r].head + runs[runs[r].head].span

HandlesMatchStorage ==
  /\ liveHandles \cap staleHandles = {}
  /\ \A handle \in liveHandles :
       /\ generations[handle.unit] = handle.gen
       /\ LET run == handle.unit \div SlotsPerRun
              slot == handle.unit % SlotsPerRun
          IN (runs[run].kind = "small" /\ slot \in runs[run].bitmap)
             \/ (runs[run].kind = "large-head" /\ slot = 0)

NoOverlappingLiveHandles ==
  \A left, right \in liveHandles :
    left = right \/ left.unit # right.unit

GuardOwnsMutation == phase = "idle" <=> ~guard

NoFalseExhaustion == result = "exhausted" => ~CanAllocateAfterReclaim(request)

OperationTermination == [](phase # "idle" => <> (phase = "idle"))

=============================================================================
