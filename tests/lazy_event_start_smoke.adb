with Flyology;
with Flyology.Execution_Groups;
with Flyology.IO;
with System;

procedure Lazy_Event_Start_Smoke is
   package Groups renames Flyology.Execution_Groups;

   use type Groups.Group_Id;
   use type System.Address;

   function Current_Thread return System.Address;
   pragma Import (C, Current_Thread, "pthread_self");

   Environment_Thread : constant System.Address := Current_Thread;

   protected Observation is
      procedure Report
        (Lightweight : Boolean;
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
        (Lightweight : Boolean;
         Group   : Groups.Group_Id;
         Thread  : System.Address)
      is
      begin
         OK := Lightweight
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

   task type Lightweight_Worker is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Lightweight_Worker;

   task body Lightweight_Worker is
   begin
      Observation.Report
        (Flyology.IO.Is_Lightweight_Task,
         Groups.Current,
         Current_Thread);
   end Lightweight_Worker;

   type Lightweight_Worker_Access is access Lightweight_Worker;
begin
   --  No lightweight object has been created yet. The environment task must stay
   --  on stock GNARL rather than serving as an eagerly captured group-0 fiber.
   if Flyology.IO.Is_Lightweight_Task then
      raise Program_Error with "environment task became lightweight";
   end if;
   if Groups.Configured_Pool_Size /= 1
     or else not Groups.In_Configured_Pool (Groups.Default_Group)
     or else Groups.In_Configured_Pool (1)
   then
      raise Program_Error with "default loop-pool compatibility changed";
   end if;

   declare
      Worker : constant Lightweight_Worker_Access := new Lightweight_Worker;
      pragma Unreferenced (Worker);
   begin
      Observation.Wait;
   end;

   if not Observation.Passed then
      raise Program_Error with "first event group was not started lazily";
   end if;
end Lazy_Event_Start_Smoke;
