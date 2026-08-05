with Ada.Real_Time;
with Interfaces.C;

package body Structured_Server_Test_Control is

   use type Ada.Real_Time.Time;
   use type Interfaces.C.int;

   procedure C_Reset
     with Import,
          Convention => C,
          External_Name => "flyology_test_structured_server_barrier_reset";
   procedure C_Arm (Point : Interfaces.C.int)
     with Import,
          Convention => C,
          External_Name => "flyology_test_structured_server_barrier_arm";
   function C_Reached (Point : Interfaces.C.int) return Interfaces.C.int
     with Import,
          Convention => C,
          External_Name => "flyology_test_structured_server_barrier_reached";
   procedure C_Release (Point : Interfaces.C.int)
     with Import,
          Convention => C,
          External_Name => "flyology_test_structured_server_barrier_release";

   procedure Reset is
   begin
      C_Reset;
   end Reset;

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
            raise Program_Error with
              "structured server test barrier was not reached";
         end if;
         delay 0.001;
      end loop;
   end Wait_Reached;

   procedure Release (Point : Barrier_Point) is
   begin
      C_Release (Barrier_Point'Pos (Point));
   end Release;

end Structured_Server_Test_Control;
