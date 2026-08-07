package body Flyology.Channel_Policy
  with SPARK_Mode
is
   function Classify_Send
     (Stopped  : Boolean;
      Count    : Natural;
      Capacity : Positive) return Send_Action
   is
     (if Stopped then Reject_Send
      elsif Count = Capacity then Wait_To_Send
      else Accept_Send);

   function Send_Entry_Open
     (Stopped  : Boolean;
      Count    : Natural;
      Capacity : Positive) return Boolean
   is
     (Stopped or else Count < Capacity);

   function Classify_Receive
     (Stopped : Boolean;
      Count   : Natural) return Receive_Action
   is
     (if Count > 0 then Accept_Receive
      elsif Stopped then Reject_Receive
      else Wait_To_Receive);

   function Receive_Entry_Open
     (Stopped : Boolean;
      Count   : Natural) return Boolean
   is
     (Stopped or else Count > 0);

   function Advance
     (Position : Positive;
      Capacity : Positive) return Positive
   is
     (if Position = Capacity then 1 else Position + 1);

   function Count_After_Send
     (Count    : Natural;
      Capacity : Positive) return Positive
   is
     (Count + 1);

   function Count_After_Receive (Count : Positive) return Natural is
     (Count - 1);

   function Next_Enqueue
     (Tail     : Positive;
      Count    : Natural;
      Capacity : Positive) return Enqueue_Transition
   is
     (Filled_Position => Tail,
      Next_Tail       => Advance (Tail, Capacity),
      Next_Count      => Count_After_Send (Count, Capacity));

   procedure Apply_Enqueue
     (Tail            : in out Positive;
      Count           : in out Natural;
      Capacity        : Positive;
      Filled_Position : out Positive)
   is
      Transition : constant Enqueue_Transition :=
        Next_Enqueue (Tail, Count, Capacity);
   begin
      Filled_Position := Transition.Filled_Position;
      Tail := Transition.Next_Tail;
      Count := Transition.Next_Count;
   end Apply_Enqueue;

   function Next_Dequeue
     (Head     : Positive;
      Count    : Positive;
      Capacity : Positive) return Dequeue_Transition
   is
     (Vacated_Position => Head,
      Next_Head        => Advance (Head, Capacity),
      Next_Count       => Count_After_Receive (Count));

   procedure Apply_Dequeue
     (Head             : in out Positive;
      Count            : in out Natural;
      Capacity         : Positive;
      Vacated_Position : out Positive)
   is
      Transition : constant Dequeue_Transition :=
        Next_Dequeue (Head, Positive (Count), Capacity);
   begin
      Vacated_Position := Transition.Vacated_Position;
      Head := Transition.Next_Head;
      Count := Transition.Next_Count;
   end Apply_Dequeue;

   function Is_Drained
     (Stopped : Boolean;
      Count   : Natural) return Boolean
   is
     (Stopped and then Count = 0);
end Flyology.Channel_Policy;
