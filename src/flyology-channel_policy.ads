--  Internal, proved ring and close/drain decisions for bounded channels.
--  Protected-entry serialization and element storage remain in the generic
--  channel implementation that consumes these decisions.
private package Flyology.Channel_Policy
  with Preelaborate,
       SPARK_Mode
is
   type Send_Action is (Accept_Send, Wait_To_Send, Reject_Send);
   type Receive_Action is
     (Accept_Receive, Wait_To_Receive, Reject_Receive);

   --  Distinguish acceptance, capacity wait, and terminal rejection.
   function Classify_Send
     (Stopped  : Boolean;
      Count    : Natural;
      Capacity : Positive) return Send_Action
   with Pre  => Count <= Capacity,
        Post =>
          (if Stopped then
              Classify_Send'Result = Reject_Send
           elsif Count = Capacity then
              Classify_Send'Result = Wait_To_Send
           else
              Classify_Send'Result = Accept_Send);

   --  Open Send for either acceptance or terminal rejection.
   function Send_Entry_Open
     (Stopped  : Boolean;
      Count    : Natural;
      Capacity : Positive) return Boolean
   with Pre  => Count <= Capacity,
        Post => Send_Entry_Open'Result =
          (Stopped or else Count < Capacity);

   --  Distinguish delivery, value wait, and drained-channel rejection.
   function Classify_Receive
     (Stopped : Boolean;
      Count   : Natural) return Receive_Action
   with Post =>
     (if Count > 0 then
         Classify_Receive'Result = Accept_Receive
      elsif Stopped then
         Classify_Receive'Result = Reject_Receive
      else
         Classify_Receive'Result = Wait_To_Receive);

   --  Open Receive for either delivery or terminal rejection.
   function Receive_Entry_Open
     (Stopped : Boolean;
      Count   : Natural) return Boolean
   with Post => Receive_Entry_Open'Result = (Stopped or else Count > 0);

   --  Advance one circular-buffer index while retaining one-based bounds.
   function Advance
     (Position : Positive;
      Capacity : Positive) return Positive
   with Pre  => Position <= Capacity,
        Post => Advance'Result <= Capacity
          and then Advance'Result =
            (if Position = Capacity then 1 else Position + 1);

   --  Increment the buffered count without exceeding capacity.
   function Count_After_Send
     (Count    : Natural;
      Capacity : Positive) return Positive
   with Pre  => Count < Capacity,
        Post => Count_After_Send'Result = Count + 1
          and then Count_After_Send'Result <= Capacity;

   --  Decrement a nonempty buffered count.
   function Count_After_Receive (Count : Positive) return Natural
   with Post => Count_After_Receive'Result = Count - 1;

   type Enqueue_Transition is record
      Filled_Position : Positive;
      Next_Tail       : Positive;
      Next_Count      : Positive;
   end record;

   --  Bind the slot filled by one enqueue to the old tail and carry the
   --  corresponding tail and count updates as one transition.
   function Next_Enqueue
     (Tail     : Positive;
      Count    : Natural;
      Capacity : Positive) return Enqueue_Transition
   with Global => null,
        Pre    => Tail <= Capacity and then Count < Capacity,
        Post   =>
          Next_Enqueue'Result.Filled_Position = Tail
          and then Next_Enqueue'Result.Next_Tail = Advance (Tail, Capacity)
          and then Next_Enqueue'Result.Next_Count =
            Count_After_Send (Count, Capacity);

   --  Commit the scalar portion of an enqueue and return the old-tail slot
   --  that the caller must fill with the transferred value.
   procedure Apply_Enqueue
     (Tail            : in out Positive;
      Count           : in out Natural;
      Capacity        : Positive;
      Filled_Position : out Positive)
   with Global => null,
        Pre    => Tail <= Capacity and then Count < Capacity,
        Post   =>
          Filled_Position =
            Next_Enqueue (Tail'Old, Count'Old, Capacity).Filled_Position
          and then Tail =
            Next_Enqueue (Tail'Old, Count'Old, Capacity).Next_Tail
          and then Count =
            Next_Enqueue (Tail'Old, Count'Old, Capacity).Next_Count;

   type Dequeue_Transition is record
      Vacated_Position : Positive;
      Next_Head        : Positive;
      Next_Count       : Natural;
   end record;

   --  Bind the slot vacated by one dequeue to the old head and carry the
   --  corresponding head and count updates as one transition.
   function Next_Dequeue
     (Head     : Positive;
      Count    : Positive;
      Capacity : Positive) return Dequeue_Transition
   with Global => null,
        Pre    => Head <= Capacity and then Count <= Capacity,
        Post   =>
          Next_Dequeue'Result.Vacated_Position = Head
          and then Next_Dequeue'Result.Next_Head = Advance (Head, Capacity)
          and then Next_Dequeue'Result.Next_Count =
            Count_After_Receive (Count);

   --  Commit the scalar portion of a dequeue and return the old-head slot
   --  that the caller must clear after copying its value.
   procedure Apply_Dequeue
     (Head             : in out Positive;
      Count            : in out Natural;
      Capacity         : Positive;
      Vacated_Position : out Positive)
   with Global => null,
        Pre    => Head <= Capacity and then Count in 1 .. Capacity,
        Post   =>
          Vacated_Position =
            Next_Dequeue
              (Head'Old, Positive (Count'Old), Capacity).Vacated_Position
          and then Head =
            Next_Dequeue
              (Head'Old, Positive (Count'Old), Capacity).Next_Head
          and then Count =
            Next_Dequeue
              (Head'Old, Positive (Count'Old), Capacity).Next_Count;

   --  Open the drain barrier only after close reaches an empty buffer.
   function Is_Drained
     (Stopped : Boolean;
      Count   : Natural) return Boolean
   with Post => Is_Drained'Result = (Stopped and then Count = 0);
end Flyology.Channel_Policy;
