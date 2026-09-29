---- MODULE AllocatorAlgorithmsRefinement ----
EXTENDS AllocatorAlgorithms, Sequences, TLC

(***************************************************************************
This module constrains the bounded allocator model to the same sequential
operation traces executed by the standalone Ada refinement harness.  Each
completed public operation prints one canonical abstraction of the model
state.  The maintained runner compares those lines with snapshots read from
the real Buddy, Best-Fit, and TLSF metadata.

The comparison is deliberately at the reviewed abstraction boundary: active
physical extents, live allocation generations, logical free-index membership,
real TLSF class membership and bitmaps, Buddy view-local hints, live handles,
results, and the global generation.  Free-block generation bytes are
normalized because they cannot validate a handle.  AVL shape, inactive Buddy
descendants, TLSF list order, native addresses, and raw padding remain outside
the model and outside the comparison.
***************************************************************************)

VARIABLE tracePosition

refinementVars == <<vars, tracePosition>>

ClientOrder == <<"a", "b", "c", "d">>

BuddyTrace ==
  <<[kind |-> "allocate", client |-> "a", size |-> 4],
    [kind |-> "release",  client |-> "a", size |-> 0],
    [kind |-> "allocate", client |-> "b", size |-> 4],
    [kind |-> "allocate", client |-> "a", size |-> 4],
    [kind |-> "release",  client |-> "b", size |-> 0],
    [kind |-> "release",  client |-> "a", size |-> 0],
    [kind |-> "allocate", client |-> "c", size |-> 8],
    [kind |-> "release",  client |-> "c", size |-> 0],
    [kind |-> "allocate", client |-> "c", size |-> 8],
    [kind |-> "release",  client |-> "c", size |-> 0]>>

InBandTrace ==
  <<[kind |-> "allocate", client |-> "a", size |-> 2],
    [kind |-> "allocate", client |-> "b", size |-> 2],
    [kind |-> "allocate", client |-> "c", size |-> 2],
    [kind |-> "allocate", client |-> "d", size |-> 2],
    [kind |-> "release",  client |-> "b", size |-> 0],
    [kind |-> "release",  client |-> "c", size |-> 0],
    [kind |-> "allocate", client |-> "b", size |-> 4],
    [kind |-> "release",  client |-> "b", size |-> 0],
    [kind |-> "release",  client |-> "a", size |-> 0],
    [kind |-> "release",  client |-> "d", size |-> 0],
    [kind |-> "allocate", client |-> "a", size |-> 8],
    [kind |-> "release",  client |-> "a", size |-> 0]>>

Trace == IF Algorithm = "Buddy" THEN BuddyTrace ELSE InBandTrace

RECURSIVE SetToSequence(_)
SetToSequence(values) ==
  IF values = {}
  THEN <<>>
  ELSE LET value == CHOOSE candidate \in values : TRUE
       IN Append(SetToSequence(values \ {value}), value)

BlockBefore(left, right) == left.start < right.start
KeyBefore(left, right) == left.start < right.start

OrderedBlocks == SortSeq(SetToSequence(blocks), BlockBefore)
OrderedIndex == SortSeq(SetToSequence(freeIndex), KeyBefore)

StateText(block) == IF block.state = "free" THEN "F" ELSE "A"
GenerationText(block) ==
  IF block.state = "free" THEN "0" ELSE ToString(block.gen)

BlockText(block) ==
  ToString(block.start) \o ":" \o ToString(block.size) \o ":"
  \o StateText(block) \o ":" \o GenerationText(block)

RECURSIVE BlockSequenceText(_, _)
BlockSequenceText(sequence, position) ==
  IF position > Len(sequence)
  THEN ""
  ELSE (IF position = 1 THEN "" ELSE ",")
       \o BlockText(sequence[position])
       \o BlockSequenceText(sequence, position + 1)

BlocksText ==
  IF Len(OrderedBlocks) = 0 THEN "-"
  ELSE BlockSequenceText(OrderedBlocks, 1)

KeyText(key) == ToString(key.start) \o ":" \o ToString(key.size)

RECURSIVE IndexSequenceText(_, _)
IndexSequenceText(sequence, position) ==
  IF position > Len(sequence)
  THEN ""
  ELSE (IF position = 1 THEN "" ELSE ",")
       \o KeyText(sequence[position])
       \o IndexSequenceText(sequence, position + 1)

IndexText ==
  IF Len(OrderedIndex) = 0 THEN "-"
  ELSE IndexSequenceText(OrderedIndex, 1)

FirstClass(size) ==
  IF size >= 8 THEN 3
  ELSE IF size >= 4 THEN 2
  ELSE IF size >= 2 THEN 1
  ELSE 0

ClassBase(size) ==
  IF FirstClass(size) = 3 THEN 8
  ELSE IF FirstClass(size) = 2 THEN 4
  ELSE IF FirstClass(size) = 1 THEN 2
  ELSE 1

SecondClass(size) ==
  ((size - ClassBase(size)) * 16) \div ClassBase(size)

ClassText(key) ==
  KeyText(key) \o ":" \o ToString(FirstClass(key.size)) \o ":"
  \o ToString(SecondClass(key.size))

RECURSIVE ClassSequenceText(_, _)
ClassSequenceText(sequence, position) ==
  IF position > Len(sequence)
  THEN ""
  ELSE (IF position = 1 THEN "" ELSE ",")
       \o ClassText(sequence[position])
       \o ClassSequenceText(sequence, position + 1)

ClassesText ==
  IF Algorithm # "TLSF" \/ Len(OrderedIndex) = 0 THEN "-"
  ELSE ClassSequenceText(OrderedIndex, 1)

RECURSIVE BitmapValue(_)
BitmapValue(values) ==
  IF values = {}
  THEN 0
  ELSE LET value == CHOOSE candidate \in values : TRUE
       IN (2 ^ value) + BitmapValue(values \ {value})

FirstMapValue ==
  BitmapValue({FirstClass(size) : size \in bitmap})

SecondMapValue(first) ==
  BitmapValue
    ({SecondClass(size) :
        size \in {candidate \in bitmap : FirstClass(candidate) = first}})

RECURSIVE SecondMapsText(_)
SecondMapsText(first) ==
  IF first = 32
  THEN ""
  ELSE (IF first = 0 THEN "" ELSE ",")
       \o ToString(SecondMapValue(first))
       \o SecondMapsText(first + 1)

MapsText ==
  IF Algorithm # "TLSF" THEN "-"
  ELSE ToString(FirstMapValue) \o ":" \o SecondMapsText(0)

RECURSIVE HintValuesText(_, _)
HintValuesText(client, size) ==
  IF size > Capacity
  THEN ""
  ELSE (IF size = 1 THEN "" ELSE ",")
       \o ToString(hints[client][size])
       \o HintValuesText(client, size + 1)

HintClientText(client) == client \o ":" \o HintValuesText(client, 1)

HintsText ==
  HintClientText("a") \o ";" \o HintClientText("b") \o ";"
  \o HintClientText("c") \o ";" \o HintClientText("d")

HandleText(client) ==
  client \o ":" \o ToString(handle[client].start) \o ":"
  \o ToString(handle[client].gen)

HandlesText ==
  HandleText("a") \o ";" \o HandleText("b") \o ";"
  \o HandleText("c") \o ";" \o HandleText("d")

OperationText(operationValue) ==
  operationValue.kind \o "-" \o operationValue.client

CanonicalLine(step, operationValue, operationResult) ==
  "@@REFINEMENT@@|" \o Algorithm \o "|" \o ToString(step) \o "|"
  \o OperationText(operationValue) \o "|"
  \o ToString(operationValue.size) \o "|" \o operationResult
  \o "|gen=" \o ToString(generation)
  \o "|blocks=" \o BlocksText
  \o "|index=" \o IndexText
  \o "|classes=" \o ClassesText
  \o "|maps=" \o MapsText
  \o "|hints=" \o HintsText
  \o "|handles=" \o HandlesText

InitialOperation == [kind |-> "init", client |-> "", size |-> 0]

RefinementInit ==
  /\ Init
  /\ tracePosition = 1
  /\ PrintT
       ("@@REFINEMENT@@|" \o Algorithm
        \o "|0|init|0|none|gen=" \o ToString(generation)
        \o "|blocks=" \o BlocksText
        \o "|index=" \o IndexText
        \o "|classes=" \o ClassesText
        \o "|maps=" \o MapsText
        \o "|hints=" \o HintsText
        \o "|handles=" \o HandlesText)

StartTraceOperation ==
  /\ tracePosition <= Len(Trace)
  /\ LET operationValue == Trace[tracePosition]
         client == operationValue.client
     IN IF operationValue.kind = "allocate"
        THEN StartAllocate(client, operationValue.size)
        ELSE StartRelease(client, handle[client])
  /\ UNCHANGED tracePosition

RefinementProgress(client) ==
  SelectCandidate(client)
  \/ BeginCoalesce(client)
  \/ CoalesceStep(client)
  \/ FinishCoalesce(client)
  \/ RetrySearch(client)
  \/ SplitBuddyCandidate(client)
  \/ CommitAllocation(client)
  \/ ValidateRelease(client)
  \/ FinishOperation(client)

RecordAndClear ==
  /\ tracePosition <= Len(Trace)
  /\ LET operationValue == Trace[tracePosition]
         client == operationValue.client
     IN /\ phase[client] = "done"
        /\ PrintT
             (CanonicalLine
                (tracePosition, operationValue, result[client]))
        /\ ClearResult(client)
  /\ tracePosition' = tracePosition + 1

RefinementNext ==
  \/ StartTraceOperation
  \/ \E client \in Clients :
       /\ UNCHANGED tracePosition
       /\ (Acquire(client) \/ RefinementProgress(client))
  \/ RecordAndClear

RefinementSpec ==
  RefinementInit
  /\ [][RefinementNext]_refinementVars
  /\ WF_refinementVars(RefinementNext)

TraceCompletion == <>(tracePosition = Len(Trace) + 1)

=============================================================================
