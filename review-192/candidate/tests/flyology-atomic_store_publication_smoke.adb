with Ada.Text_IO;
with Flyology.Atomic_Primitives;
with Interfaces;

procedure Flyology.Atomic_Store_Publication_Smoke is
   package Atomic renames Flyology.Atomic_Primitives;

   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   Iterations : constant := 10_000;

   Payload_U32      : Interfaces.Unsigned_32 := 0 with Volatile;
   Ready_U32        : aliased Interfaces.Unsigned_32 := 0 with Alignment => 4;
   Acknowledged_U32 : aliased Interfaces.Unsigned_32 := 0 with Alignment => 4;
   Payload_U64      : Interfaces.Unsigned_64 := 0 with Volatile;
   Ready_U64        : aliased Interfaces.Unsigned_64 := 0 with Alignment => 8;
   Acknowledged_U64 : aliased Interfaces.Unsigned_64 := 0 with Alignment => 8;

   task Publisher;

   task body Publisher is
   begin
      for Sequence in 1 .. Iterations loop
         while Atomic.Load_Acquire_U32 (Acknowledged_U32'Address) /= Interfaces.Unsigned_32 (Sequence - 1)
         loop
            delay 0.0;
         end loop;
         Payload_U32 := Interfaces.Unsigned_32 (Sequence) xor 16#A5A5_5A5A#;
         Atomic.Store_Release_U32 (Ready_U32'Address, Interfaces.Unsigned_32 (Sequence));
      end loop;

      for Sequence in 1 .. Iterations loop
         while Atomic.Load_Acquire_U64 (Acknowledged_U64'Address) /= Interfaces.Unsigned_64 (Sequence - 1)
         loop
            delay 0.0;
         end loop;
         Payload_U64 := Interfaces.Unsigned_64 (Sequence) xor 16#A5A5_5A5A_F0F0_0F0F#;
         Atomic.Store_Release_U64 (Ready_U64'Address, Interfaces.Unsigned_64 (Sequence));
      end loop;
   end Publisher;

begin
   for Sequence in 1 .. Iterations loop
      while Atomic.Load_Acquire_U32 (Ready_U32'Address) /= Interfaces.Unsigned_32 (Sequence) loop
         delay 0.0;
      end loop;
      if Payload_U32 /= (Interfaces.Unsigned_32 (Sequence) xor 16#A5A5_5A5A#) then
         raise Program_Error with "32-bit release/acquire publication failed";
      end if;
      Atomic.Store_Release_U32 (Acknowledged_U32'Address, Interfaces.Unsigned_32 (Sequence));
   end loop;

   for Sequence in 1 .. Iterations loop
      while Atomic.Load_Acquire_U64 (Ready_U64'Address) /= Interfaces.Unsigned_64 (Sequence) loop
         delay 0.0;
      end loop;
      if Payload_U64 /= (Interfaces.Unsigned_64 (Sequence) xor 16#A5A5_5A5A_F0F0_0F0F#) then
         raise Program_Error with "64-bit release/acquire publication failed";
      end if;
      Atomic.Store_Release_U64 (Acknowledged_U64'Address, Interfaces.Unsigned_64 (Sequence));
   end loop;

   Ada.Text_IO.Put_Line ("atomic-store release/acquire publication: PASS");
end Flyology.Atomic_Store_Publication_Smoke;
