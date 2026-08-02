with Ada.Command_Line;
with Ada.Text_IO;
with Gnatevl;
with Gnatevl.IO;
with Gnatevl.IO.Timers;
with Gnatevl.Observability;

procedure External_Consumer is
   Expected_Evented : constant Boolean :=
     Ada.Command_Line.Argument_Count = 1
     and then Ada.Command_Line.Argument (1) = "evented";

   protected Observation is
      procedure Report (Evented : Boolean);
      entry Wait;
      function Passed return Boolean;
   private
      Done : Boolean := False;
      OK   : Boolean := False;
   end Observation;

   protected body Observation is
      procedure Report (Evented : Boolean) is
      begin
         OK := Evented = Expected_Evented;
         Done := True;
      end Report;

      entry Wait when Done is
      begin
         null;
      end Wait;

      function Passed return Boolean is (OK);
   end Observation;

   task type Default_Worker (Model : Gnatevl.Execution_Model) is
      pragma Task_Info (Model);
   end Default_Worker;

   task body Default_Worker is
   begin
      Gnatevl.IO.Timers.Sleep_For (0.001);
      Observation.Report (Gnatevl.IO.Is_Evented_Task);
   end Default_Worker;

   type Default_Worker_Access is access Default_Worker;
   Snapshot : Gnatevl.Observability.Group_Snapshot;
begin
   if Ada.Command_Line.Argument_Count /= 1
     or else
       (Ada.Command_Line.Argument (1) /= "native"
        and then Ada.Command_Line.Argument (1) /= "evented")
   then
      raise Program_Error with "expected native or evented argument";
   end if;

   if Gnatevl.IO.Is_Evented_Task then
      raise Program_Error with "environment task became evented";
   end if;

   if Gnatevl.Observability.Snapshot (0, Snapshot) then
      raise Program_Error with "event loop started before opt-in";
   end if;

   declare
      Worker : constant Default_Worker_Access :=
        new Default_Worker (Gnatevl.Project_Default);
      pragma Unreferenced (Worker);
   begin
      Observation.Wait;
   end;

   if not Observation.Passed then
      raise Program_Error with "prepared project default was not honored";
   end if;

   if Gnatevl.Observability.Snapshot (0, Snapshot) /= Expected_Evented then
      raise Program_Error with "runtime machinery inertness did not match mode";
   end if;

   Ada.Text_IO.Put_Line
     ("external Alire consumer: " & Ada.Command_Line.Argument (1) & " passed");
end External_Consumer;
