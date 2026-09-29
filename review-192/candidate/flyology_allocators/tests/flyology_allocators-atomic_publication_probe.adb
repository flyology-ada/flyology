with Ada.Text_IO;
with Flyology_Allocators.Atomics;
with Interfaces;

procedure Flyology_Allocators.Atomic_Publication_Probe is
   package Atomic renames Flyology_Allocators.Atomics;

   use type Interfaces.Unsigned_32;

   Iterations : constant := 10_000;

   Payload      : Interfaces.Unsigned_32 := 0 with Volatile;
   Ready        : aliased Interfaces.Unsigned_32 := 0 with Alignment => 4;
   Acknowledged : aliased Interfaces.Unsigned_32 := 0 with Alignment => 4;

   task Publisher;

   task body Publisher is
   begin
      for Sequence in 1 .. Iterations loop
         while Atomic.Load_Acquire_U32 (Acknowledged'Address) /= Interfaces.Unsigned_32 (Sequence - 1)
         loop
            delay 0.0;
         end loop;
         Payload := Interfaces.Unsigned_32 (Sequence) xor 16#A5A5_5A5A#;
         Atomic.Store_Release_U32 (Ready'Address, Interfaces.Unsigned_32 (Sequence));
      end loop;
   end Publisher;

begin
   for Sequence in 1 .. Iterations loop
      while Atomic.Load_Acquire_U32 (Ready'Address) /= Interfaces.Unsigned_32 (Sequence) loop
         delay 0.0;
      end loop;
      if Payload /= (Interfaces.Unsigned_32 (Sequence) xor 16#A5A5_5A5A#) then
         raise Program_Error with "standalone allocator release/acquire publication failed";
      end if;
      Atomic.Store_Release_U32 (Acknowledged'Address, Interfaces.Unsigned_32 (Sequence));
   end loop;

   Ada.Text_IO.Put_Line ("standalone allocator atomic publication: PASS");
end Flyology_Allocators.Atomic_Publication_Probe;
