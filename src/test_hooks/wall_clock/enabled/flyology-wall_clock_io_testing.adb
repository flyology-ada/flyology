with Ada.Unchecked_Conversion;
with System.Atomic_Primitives;

package body Flyology.Wall_Clock_IO_Testing is
   package Atomics renames System.Atomic_Primitives;
   use type Atomics.uint32;

   function To_Bits is new Ada.Unchecked_Conversion (Interfaces.Integer_64, Atomics.uint64);
   function To_Integer is new Ada.Unchecked_Conversion (Atomics.uint64, Interfaces.Integer_64);

   Requested_Steady : aliased Atomics.uint64 := 0;
   Requested_Wall   : aliased Atomics.uint64 := 0;
   Current_Steady   : aliased Atomics.uint64 := 0;
   Current_Wall     : aliased Atomics.uint64 := 0;
   Pending          : aliased Atomics.uint32 := 0;
   Count            : aliased Atomics.uint32 := 0;

   procedure Configure (Steady_Nanoseconds : Interfaces.Integer_64; Wall_Nanoseconds : Interfaces.Integer_64)
   is
   begin
      Atomics.Atomic_Store_64 (Requested_Steady'Address, To_Bits (Steady_Nanoseconds), Atomics.Relaxed);
      Atomics.Atomic_Store_64 (Requested_Wall'Address, To_Bits (Wall_Nanoseconds), Atomics.Relaxed);
      Atomics.Atomic_Store_64 (Current_Steady'Address, 0, Atomics.Relaxed);
      Atomics.Atomic_Store_64 (Current_Wall'Address, 0, Atomics.Relaxed);
      Atomics.Atomic_Store_32 (Count'Address, 0, Atomics.Relaxed);
      Atomics.Atomic_Store_32 (Pending'Address, 1, Atomics.Relaxed);
   end Configure;

   procedure Reset is
   begin
      Configure (0, 0);
      Atomics.Atomic_Store_32 (Pending'Address, 0, Atomics.Relaxed);
   end Reset;

   function Take_EINTR return Boolean is
      Expected      : aliased Atomics.uint32 := 1;
      Current_Count : aliased Atomics.uint32;
   begin
      if not Atomics.Atomic_Compare_Exchange_32
               (Pending'Address,
                Expected'Address,
                0,
                Weak          => False,
                Success_Model => Atomics.Relaxed,
                Failure_Model => Atomics.Relaxed)
      then
         return False;
      end if;
      Atomics.Atomic_Store_64
        (Current_Steady'Address,
         Atomics.Atomic_Load_64 (Requested_Steady'Address, Atomics.Relaxed),
         Atomics.Relaxed);
      Atomics.Atomic_Store_64
        (Current_Wall'Address,
         Atomics.Atomic_Load_64 (Requested_Wall'Address, Atomics.Relaxed),
         Atomics.Relaxed);
      Current_Count := Atomics.Atomic_Load_32 (Count'Address, Atomics.Relaxed);
      loop
         exit when
           Atomics.Atomic_Compare_Exchange_32
             (Count'Address,
              Current_Count'Address,
              Current_Count + 1,
              Weak          => True,
              Success_Model => Atomics.Relaxed,
              Failure_Model => Atomics.Relaxed);
      end loop;
      return True;
   end Take_EINTR;

   function Steady_Adjustment return Interfaces.Integer_64
   is (To_Integer (Atomics.Atomic_Load_64 (Current_Steady'Address, Atomics.Relaxed)));

   function Wall_Adjustment return Interfaces.Integer_64
   is (To_Integer (Atomics.Atomic_Load_64 (Current_Wall'Address, Atomics.Relaxed)));

   function Retry_Count return Natural
   is (Natural (Atomics.Atomic_Load_32 (Count'Address, Atomics.Relaxed)));
end Flyology.Wall_Clock_IO_Testing;
