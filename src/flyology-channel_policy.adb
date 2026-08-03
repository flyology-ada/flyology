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

   function Is_Drained
     (Stopped : Boolean;
      Count   : Natural) return Boolean
   is
     (Stopped and then Count = 0);
end Flyology.Channel_Policy;
