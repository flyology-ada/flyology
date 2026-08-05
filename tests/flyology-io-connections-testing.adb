with Ada.Real_Time;
with Interfaces.C;

package body Flyology.IO.Connections.Testing is

   use type Ada.Real_Time.Time;
   use type Interfaces.C.int;

   procedure C_Reset
     with Import,
          Convention => C,
          External_Name => "flyology_test_connection_barrier_reset";
   procedure C_Arm (Point : Interfaces.C.int)
     with Import,
          Convention => C,
          External_Name => "flyology_test_connection_barrier_arm";
   function C_Reached (Point : Interfaces.C.int) return Interfaces.C.int
     with Import,
          Convention => C,
          External_Name => "flyology_test_connection_barrier_reached";
   procedure C_Release (Point : Interfaces.C.int)
     with Import,
          Convention => C,
          External_Name => "flyology_test_connection_barrier_release";
   procedure C_Fail_Next_Release_Wake
     with Import,
          Convention => C,
          External_Name =>
            "flyology_test_connection_arm_capacity_release_wake_failure";

   function Waiting_Operations (Item : Connection) return Natural is
     (Item.Controller.Waiting_Count);

   function Operation_Active (Item : Connection) return Boolean is
     (Item.Controller.Lease_Active);

   function Close_Requested (Item : Connection) return Boolean is
     (Item.Controller.Close_Pending);

   procedure Reset_Barriers is
   begin
      C_Reset;
   end Reset_Barriers;

   procedure Arm (Point : Barrier_Point) is
   begin
      C_Arm (Barrier_Point'Pos (Point));
   end Arm;

   procedure Wait_Reached (Point : Barrier_Point) is
      Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
   begin
      while C_Reached (Barrier_Point'Pos (Point)) = 0 loop
         if Ada.Real_Time.Clock >= Deadline then
            raise Program_Error with "connection test barrier was not reached";
         end if;
         delay 0.001;
      end loop;
   end Wait_Reached;

   procedure Release (Point : Barrier_Point) is
   begin
      C_Release (Barrier_Point'Pos (Point));
   end Release;

   procedure Fail_Next_Release_Wake is
   begin
      C_Fail_Next_Release_Wake;
   end Fail_Next_Release_Wake;

end Flyology.IO.Connections.Testing;
