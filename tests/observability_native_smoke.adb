with Flyology;
with Flyology.Observability;

procedure Observability_Native_Smoke is
   package Observation renames Flyology.Observability;

   use type Observation.Fatal_Context;

   Sample : Observation.Group_Snapshot;

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

      function Passed return Boolean is (OK);
   end Result;

   task Native is
      pragma Task_Info (Flyology.Native_Task);
   end Native;

   task body Native is
      Local : Observation.Group_Snapshot;
   begin
      Result.Set (not Observation.Snapshot (0, Local));
   end Native;
begin
   if Observation.Last_Fatal /= Observation.No_Fatal then
      raise Program_Error with "fresh runtime retained fatal context";
   end if;
   if Observation.Snapshot (0, Sample) then
      raise Program_Error with "observation eagerly created event group 0";
   end if;
   Result.Wait;
   if not Result.Passed or else Observation.Snapshot (0, Sample) then
      raise Program_Error with "native-only observation was not inert";
   end if;
end Observability_Native_Smoke;
