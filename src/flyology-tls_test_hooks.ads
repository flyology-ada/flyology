--  Test-only TLS ownership-transfer barrier state. The project excludes this
--  unit completely unless FLYOLOGY_TLS_TEST_HOOKS is enabled.
private package Flyology.TLS_Test_Hooks
  with SPARK_Mode => On,
       Abstract_State =>
         (Barrier_State with
            External => (Async_Readers, Async_Writers)),
       Initializes => Barrier_State
is
   Barrier_Count : constant := 2;

   function Valid_Point (Point : Integer) return Boolean
   with
     Global => null,
     Post => Valid_Point'Result = (Point >= 0 and then Point < Barrier_Count);

   procedure Reset
   with Global => (Output => Barrier_State);

   procedure Arm (Point : Integer)
   with Global => (In_Out => Barrier_State);

   procedure Arrive (Point : Integer; Did_Arrive : out Boolean)
   with
     Global => (In_Out => Barrier_State),
     Post => (if not Valid_Point (Point) then not Did_Arrive);

   function Reached (Point : Integer) return Boolean
   with
     Global => (Input => Barrier_State),
     Post => (if not Valid_Point (Point) then not Reached'Result);

   function Released (Point : Integer) return Boolean
   with
     Global => (Input => Barrier_State),
     Post => (if not Valid_Point (Point) then Released'Result);

   procedure Release (Point : Integer)
   with Global => (In_Out => Barrier_State);
end Flyology.TLS_Test_Hooks;
