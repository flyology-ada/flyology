package body Flyology.Structured_Server_Test_Hooks is
#if FLYOLOGY_STRUCTURED_SERVER_TEST_HOOKS then
   use type Interfaces.C.int;

   function Test_Barrier_Arrive (Point : Interfaces.C.int) return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_test_structured_server_barrier_arrive";
   function Test_Barrier_Released (Point : Interfaces.C.int) return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_test_structured_server_barrier_released";
   function Test_Activation_Failure return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_test_structured_server_activation_failure";

   procedure Barrier (Point : Interfaces.C.int) is
   begin
      if Test_Barrier_Arrive (Point) /= 0 then
         while Test_Barrier_Released (Point) = 0 loop
            delay 0.0;
         end loop;
      end if;
   end Barrier;

   function Check_Activation return Boolean is
   begin
      Barrier (5);
      if Test_Activation_Failure /= 0 then
         raise Program_Error with "injected structured server worker activation failure";
      end if;
      return True;
   end Check_Activation;
#else
   procedure Barrier (Point : Interfaces.C.int) is
      pragma Unreferenced (Point);
   begin
      null;
   end Barrier;

   function Check_Activation return Boolean
   is (True);
#end if;
end Flyology.Structured_Server_Test_Hooks;
