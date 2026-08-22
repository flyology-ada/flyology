with Flyology;
with Flyology.Debug_Producer_Selection;
with Flyology.Observability;

procedure Observability_Native_Smoke is
   package Observation renames Flyology.Observability;

   use type Observation.Counter;
   use type Observation.Fatal_Context;
   use type Observation.Task_Instance_Id;

   Sample     : Observation.Group_Snapshot;
   Tasks      : Observation.Task_Snapshot_Array (1 .. 1);
   Task_Count : Natural;
   Task_Total : Observation.Counter;

   protected Result is
      procedure Set (Value : Boolean);
      entry Wait;
      function Passed return Boolean;
   private
      Done : Boolean := False;
      OK   : Boolean := False;
   end Result;

   protected body Result is
      procedure Set (Value : Boolean) is
      begin
         OK := Value;
         Done := True;
      end Set;

      entry Wait when Done is
      begin
         null;
      end Wait;

      function Passed return Boolean
      is (OK);
   end Result;

   task Native is
      pragma Task_Info (Flyology.Native_Task);
   end Native;

   task body Native is
      Local : Observation.Group_Snapshot;
      First : constant Positive := Flyology.Debug_Producer_Selection.Choose (4);
   begin
      Result.Set
        (not Observation.Snapshot (0, Local)
         and then Observation.Current_Task_Instance = Observation.No_Task_Instance
         and then First in 1 .. 4
         and then Flyology.Debug_Producer_Selection.Choose (4) = First);
   end Native;
begin
   declare
      First : constant Positive := Flyology.Debug_Producer_Selection.Choose (4);
   begin
      if First not in 1 .. 4
        or else Flyology.Debug_Producer_Selection.Choose (4) /= First
        or else Flyology.Debug_Producer_Selection.Choose (1) /= 1
      then
         raise Program_Error with "native debug producer selection is unstable or out of range";
      end if;
   end;
   if Observation.Current_Task_Instance /= Observation.No_Task_Instance then
      raise Program_Error with "environment task received a lightweight task identity";
   end if;
   if Observation.Last_Fatal /= Observation.No_Fatal then
      raise Program_Error with "fresh runtime retained fatal context";
   end if;
   if Observation.Snapshot (0, Sample) then
      raise Program_Error with "observation eagerly created event group 0";
   end if;
   if Observation.Snapshot_Tasks (0, Tasks, Task_Count, Task_Total)
     or else Task_Count /= 0
     or else Task_Total /= 0
   then
      raise Program_Error with "task observation eagerly created event group 0";
   end if;
   Result.Wait;
   if not Result.Passed or else Observation.Snapshot (0, Sample) then
      raise Program_Error with "native-only observation was not inert";
   end if;
end Observability_Native_Smoke;
