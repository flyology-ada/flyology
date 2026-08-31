with Flyology.Operations;
with Interfaces;
with Interfaces.C;
with System;

package Direct_IO_Futures_Bridge is
   type Future_Kind is (Read_One, Delay_Only, Ready_Before_Arm, Read_Either, Never_Read, Write_Ready);

   Rust_Future_Error : exception;

   type Future_Operation is new Flyology.Operations.Operation with private;

   procedure Start
     (Item         : in out Future_Operation;
      Kind         : Future_Kind;
      First_FD     : Interfaces.C.int;
      Second_FD    : Interfaces.C.int;
      Delay_Millis : Natural;
      Value        : Long_Long_Integer);

   procedure Finish (Item : in out Future_Operation; Value : out Long_Long_Integer);

   function Poll_Count return Interfaces.Unsigned_64;
   function Concurrent_Polls return Interfaces.Unsigned_64;
   function Drop_Count return Interfaces.Unsigned_64;
   procedure Reset_Observations;

private
   type Future_Operation is new Flyology.Operations.Operation with record
      Handle : System.Address := System.Null_Address;
      Result : Long_Long_Integer := 0;
   end record;

   overriding
   procedure Drive (Item : in out Future_Operation; Event : Flyology.Operations.Driver_Event);

   overriding
   procedure Request_Cancellation (Item : in out Future_Operation);
end Direct_IO_Futures_Bridge;
