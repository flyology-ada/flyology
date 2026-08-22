with Interfaces.C;

package body Structured_Server_Test_Control is

   use type Interfaces.C.int;

   procedure C_Reset
   with Import, Convention => C, External_Name => "flyology_test_structured_server_barrier_reset";
   procedure C_Arm (Point : Interfaces.C.int)
   with Import, Convention => C, External_Name => "flyology_test_structured_server_barrier_arm";
   function C_Reached (Point : Interfaces.C.int) return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_test_structured_server_barrier_reached";
   procedure C_Release (Point : Interfaces.C.int)
   with Import, Convention => C, External_Name => "flyology_test_structured_server_barrier_release";
   procedure C_Fail_Activation_At (Ordinal : Interfaces.C.int)
   with Import, Convention => C, External_Name => "flyology_test_structured_server_activation_fail_at";

   procedure Reset is
   begin
      C_Reset;
   end Reset;

   procedure Arm (Point : Barrier_Point) is
   begin
      C_Arm (Barrier_Point'Pos (Point));
   end Arm;

   procedure Wait_Reached (Point : Barrier_Point) is
   begin
      --  Reaching a hook is a causal test milestone, not a timing property.
      --  The test runner bounds the complete executable so a missing
      --  transition still fails without making normal progress host-load
      --  sensitive.
      while C_Reached (Barrier_Point'Pos (Point)) = 0 loop
         delay 0.001;
      end loop;
   end Wait_Reached;

   procedure Release (Point : Barrier_Point) is
   begin
      C_Release (Barrier_Point'Pos (Point));
   end Release;

   procedure Fail_Activation_At (Ordinal : Positive) is
   begin
      C_Fail_Activation_At (Interfaces.C.int (Ordinal));
   end Fail_Activation_At;

end Structured_Server_Test_Control;
