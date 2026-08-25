with System.Atomic_Primitives;

package body Flyology.Task_Lifecycle_Test_Hooks is

   package Atomics renames System.Atomic_Primitives;
   use type Atomics.uint32;

   type Boolean_Array is array (Barrier_Point) of Boolean with Atomic_Components;

   Armed                      : Boolean_Array := (others => False);
   Arrived                    : Boolean_Array := (others => False);
   References                 : aliased Atomics.uint32 := 0;
   Force_Prepared_Final       : Boolean := False
   with Atomic;
   Interrupt_Admission_Signal : Boolean := False
   with Atomic;

   procedure Reset is
   begin
      Armed := (others => False);
      Arrived := (others => False);
      Atomics.Atomic_Store_32 (References'Address, 0, Atomics.Relaxed);
      Force_Prepared_Final := False;
      Interrupt_Admission_Signal := False;
   end Reset;

   procedure Arm (Point : Barrier_Point) is
   begin
      Arrived (Point) := False;
      Armed (Point) := True;
   end Arm;

   procedure Barrier (Point : Barrier_Point) is
   begin
      if Armed (Point) then
         Arrived (Point) := True;
         while Armed (Point) loop
            delay 0.0;
         end loop;
      end if;
   end Barrier;

   function Reached (Point : Barrier_Point) return Boolean
   is (Arrived (Point));

   procedure Release (Point : Barrier_Point) is
   begin
      Armed (Point) := False;
   end Release;

   procedure Note_Reference_Acquired is
      Current : aliased Atomics.uint32 := Atomics.Atomic_Load_32 (References'Address, Atomics.Relaxed);
   begin
      loop
         pragma Assert (Current < Atomics.uint32'Last);
         exit when
           Atomics.Atomic_Compare_Exchange_32
             (References'Address,
              Current'Address,
              Current + 1,
              Weak          => True,
              Success_Model => Atomics.Relaxed,
              Failure_Model => Atomics.Relaxed);
      end loop;
   end Note_Reference_Acquired;

   procedure Note_Reference_Released is
      Current : aliased Atomics.uint32 := Atomics.Atomic_Load_32 (References'Address, Atomics.Relaxed);
   begin
      loop
         pragma Assert (Current > 0);
         exit when
           Atomics.Atomic_Compare_Exchange_32
             (References'Address,
              Current'Address,
              Current - 1,
              Weak          => True,
              Success_Model => Atomics.Relaxed,
              Failure_Model => Atomics.Relaxed);
      end loop;
   end Note_Reference_Released;

   function Outstanding_References return Natural
   is (Natural (Atomics.Atomic_Load_32 (References'Address, Atomics.Relaxed)));

   procedure Force_Next_Prepared_Generation_Final is
   begin
      Force_Prepared_Final := True;
   end Force_Next_Prepared_Generation_Final;

   function Consume_Prepared_Generation_Final return Boolean is
      Result : constant Boolean := Force_Prepared_Final;
   begin
      Force_Prepared_Final := False;
      return Result;
   end Consume_Prepared_Generation_Final;

   procedure Interrupt_Next_Admission_Signal is
   begin
      Interrupt_Admission_Signal := True;
   end Interrupt_Next_Admission_Signal;

   function Consume_Admission_Signal_Interrupted return Boolean is
      Result : constant Boolean := Interrupt_Admission_Signal;
   begin
      Interrupt_Admission_Signal := False;
      return Result;
   end Consume_Admission_Signal_Interrupted;

end Flyology.Task_Lifecycle_Test_Hooks;
