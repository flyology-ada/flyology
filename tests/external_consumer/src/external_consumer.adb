with Ada.Command_Line;
with Ada.Text_IO;
with Flyology;
with Flyology.IO;
with Flyology.IO.Timers;
with Flyology.Observability;

procedure External_Consumer is
   Expected_Lightweight : constant Boolean :=
     Ada.Command_Line.Argument_Count = 1
     and then Ada.Command_Line.Argument (1) = "lightweight";

   protected Observation is
      procedure Report (Lightweight : Boolean);
      entry Wait;
      function Passed return Boolean;
   private
      Done : Boolean := False;
      OK   : Boolean := False;
   end Observation;

   protected body Observation is
      procedure Report (Lightweight : Boolean) is
      begin
         OK := Lightweight = Expected_Lightweight;
         Done := True;
      end Report;

      entry Wait when Done is
      begin
         null;
      end Wait;

      function Passed return Boolean is (OK);
   end Observation;

   task type Default_Worker (Model : Flyology.Execution_Model) is
      pragma Task_Info (Model);
   end Default_Worker;

   task body Default_Worker is
   begin
      Flyology.IO.Timers.Sleep_For (0.001);
      Observation.Report (Flyology.IO.Is_Lightweight_Task);
   end Default_Worker;

   type Default_Worker_Access is access Default_Worker;
   Snapshot : Flyology.Observability.Group_Snapshot;
begin
   if Ada.Command_Line.Argument_Count /= 1
     or else
       (Ada.Command_Line.Argument (1) /= "native"
        and then Ada.Command_Line.Argument (1) /= "lightweight")
   then
      raise Program_Error with "expected native or lightweight argument";
   end if;

   if Flyology.IO.Is_Lightweight_Task then
      raise Program_Error with "environment task became lightweight";
   end if;

   if Flyology.Observability.Snapshot (0, Snapshot) then
      raise Program_Error with "event loop started before opt-in";
   end if;

   declare
      Worker : constant Default_Worker_Access :=
        new Default_Worker (Flyology.Project_Default);
      pragma Unreferenced (Worker);
   begin
      Observation.Wait;
   end;

   if not Observation.Passed then
      raise Program_Error with "prepared project default was not honored";
   end if;

   if Flyology.Observability.Snapshot (0, Snapshot) /= Expected_Lightweight then
      raise Program_Error with "runtime machinery inertness did not match mode";
   end if;

   Ada.Text_IO.Put_Line
     ("external Alire consumer: " & Ada.Command_Line.Argument (1) & " passed");
end External_Consumer;
