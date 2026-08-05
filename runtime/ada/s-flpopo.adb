package body System.Flyology.Poller_Policy
  with SPARK_Mode
is
   function Plan_Batch
     (State    : Drain_State;
      Capacity : Batch_Capacity) return Batch_Plan
   is
      Result : Batch_Plan :=
        (State => State, Initial_Drain_Budget => 0);
   begin
      if State.Pending
        and then
          (Capacity > 1 or else not State.File_Only_Last_Batch)
      then
         Result.Initial_Drain_Budget := 1;
      elsif Capacity = 1 and then State.File_Only_Last_Batch then
         Result.State.File_Only_Last_Batch := False;
      end if;
      return Result;
   end Plan_Batch;

   function Remaining_Budget
     (Capacity : Batch_Capacity;
      Delivered : Batch_Count) return Drain_Budget
   is
     (Capacity - Delivered);

   function After_Wake (State : Drain_State) return Drain_State
   is
     (Pending              => True,
      File_Only_Last_Batch => State.File_Only_Last_Batch);

   function After_Drain
     (State      : Drain_State;
      May_Remain : Boolean) return Drain_State
   is
     (Pending              => May_Remain,
      File_Only_Last_Batch => State.File_Only_Last_Batch);

   function After_Batch
     (State           : Drain_State;
      Capacity        : Batch_Capacity;
      Delivered       : Batch_Count;
      Only_File_Events : Boolean) return Drain_State
   is
     (Pending              => State.Pending,
      File_Only_Last_Batch =>
        Capacity = 1
        and then Delivered = 1
        and then Only_File_Events);

end System.Flyology.Poller_Policy;
