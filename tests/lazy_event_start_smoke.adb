with Gnatevl;
with Gnatevl.Execution_Groups;
with Gnatevl.IO;
with System;

procedure Lazy_Event_Start_Smoke is
   package Groups renames Gnatevl.Execution_Groups;

   use type Groups.Group_Id;
   use type System.Address;

   function Current_Thread return System.Address;
   pragma Import (C, Current_Thread, "pthread_self");

   Environment_Thread : constant System.Address := Current_Thread;

   protected Observation is
      procedure Report
        (Evented : Boolean;
         Group   : Groups.Group_Id;
         Thread  : System.Address);
      entry Wait;
      function Passed return Boolean;
   private
      Done : Boolean := False;
      OK   : Boolean := False;
   end Observation;

   protected body Observation is
      procedure Report
        (Evented : Boolean;
         Group   : Groups.Group_Id;
         Thread  : System.Address)
      is
      begin
         OK := Evented
           and then Group = Groups.Default_Group
           and then Thread /= Environment_Thread;
         Done := True;
      end Report;

      entry Wait when Done is
      begin
         null;
      end Wait;

      function Passed return Boolean is (OK);
   end Observation;

   task type Evented_Worker is
      pragma Task_Info (Gnatevl.Event_Loop_Task);
   end Evented_Worker;

   task body Evented_Worker is
   begin
      Observation.Report
        (Gnatevl.IO.Is_Evented_Task,
         Groups.Current,
         Current_Thread);
   end Evented_Worker;

   type Evented_Worker_Access is access Evented_Worker;
begin
   --  No evented object has been created yet. The environment task must stay
   --  on stock GNARL rather than serving as an eagerly captured group-0 fiber.
   if Gnatevl.IO.Is_Evented_Task then
      raise Program_Error with "environment task became evented";
   end if;
   if Groups.Configured_Pool_Size /= 1
     or else not Groups.In_Configured_Pool (Groups.Default_Group)
     or else Groups.In_Configured_Pool (1)
   then
      raise Program_Error with "default loop-pool compatibility changed";
   end if;

   declare
      Worker : constant Evented_Worker_Access := new Evented_Worker;
      pragma Unreferenced (Worker);
   begin
      Observation.Wait;
   end;

   if not Observation.Passed then
      raise Program_Error with "first event group was not started lazily";
   end if;
end Lazy_Event_Start_Smoke;
