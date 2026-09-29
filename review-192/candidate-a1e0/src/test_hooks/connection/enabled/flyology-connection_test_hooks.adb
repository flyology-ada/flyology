package body Flyology.Connection_Test_Hooks is
   use type Interfaces.C.int;

   function Test_Barrier_Arrive (Point : Interfaces.C.int) return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_test_connection_barrier_arrive";

   function Test_Barrier_Released (Point : Interfaces.C.int) return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_test_connection_barrier_released";

   function Test_Barrier_Arrive_Once (Point : Interfaces.C.int) return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_test_connection_barrier_arrive_once";

   function Test_Receive_Limit (Requested : Interfaces.C.int) return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_test_connection_receive_limit";

   procedure Test_Raw_Accept_Return_Barrier
   with Import, Convention => C, External_Name => "flyology_test_connection_raw_accept_return_barrier";

   function Test_Fail_Next_Capacity_Release_Wake return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_test_connection_fail_next_capacity_release_wake";

   procedure Barrier (Point : Interfaces.C.int) is
   begin
      if Test_Barrier_Arrive (Point) /= 0 then
         while Test_Barrier_Released (Point) = 0 loop
            delay 0.0;
         end loop;
      end if;
   end Barrier;

   procedure One_Shot_Barrier (Point : Interfaces.C.int) is
   begin
      if Test_Barrier_Arrive_Once (Point) /= 0 then
         while Test_Barrier_Released (Point) = 0 loop
            delay 0.0;
         end loop;
      end if;
   end One_Shot_Barrier;

   function Receive_Limit (Requested : Interfaces.C.int) return Interfaces.C.int
   is (Test_Receive_Limit (Requested));

   procedure Raw_Accept_Return_Barrier is
   begin
      Test_Raw_Accept_Return_Barrier;
   end Raw_Accept_Return_Barrier;

   function Fail_Next_Capacity_Release_Wake return Boolean
   is (Test_Fail_Next_Capacity_Release_Wake /= 0);

end Flyology.Connection_Test_Hooks;
