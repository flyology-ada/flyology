--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

package body Flyology_Bench_Internal_Probes is
   overriding procedure Finalize (Object : in out Perf_Handle) is
   begin
      if Object.Initialized then
         Native_Perf_Close (Object.State'Access);
         Object.Initialized := False;
      end if;
   end Finalize;

   function Clock_Now return Interfaces.Unsigned_64 is
      Value : aliased Interfaces.Unsigned_64 := 0;
   begin
      if Native_Clock_Now (Value'Access) /= 0 then
         raise Program_Error with "platform monotonic clock read failed";
      end if;
      return Value;
   end Clock_Now;

   function Mask_Has
     (Mask : Interfaces.Unsigned_64;
      Bit  : Natural) return Boolean is
     ((Mask and Interfaces.Shift_Left (Interfaces.Unsigned_64'(1), Bit)) /= 0);

   procedure Read_Resource_Snapshot
     (Values    : out Native_Resource_Values;
      Mask      : out Interfaces.Unsigned_64;
      Available : out Boolean)
   is
      Local_Mask : aliased Interfaces.Unsigned_64 := 0;
   begin
      Values := [others => 0];
      Available := Native_Resource_Snapshot
        (Values (Values'First)'Address,
         Interfaces.C.size_t (Values'Length), Local_Mask'Access) = 0;
      Mask := Local_Mask;
   end Read_Resource_Snapshot;
end Flyology_Bench_Internal_Probes;
