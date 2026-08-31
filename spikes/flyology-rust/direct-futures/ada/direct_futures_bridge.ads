with Flyology.Operations;
with Interfaces.C;
with System;

package Direct_Futures_Bridge is
   type Future_Kind is (Self_Wake, Delayed, Panic);

   Rust_Future_Error : exception;
   Rust_Future_Panic : exception;

   type Future_Operation is new Flyology.Operations.Operation with private;

   procedure Start
     (Item : in out Future_Operation; Kind : Future_Kind; Delay_Millis : Natural; Value : Long_Long_Integer);

   procedure Finish (Item : in out Future_Operation; Value : out Long_Long_Integer);

   function Late_Wakes return Interfaces.Unsigned_64;
   function Signal_Failures return Interfaces.Unsigned_64;
   function Concurrent_Polls return Interfaces.Unsigned_64;
   procedure Reset_Observations;

private
   type Future_Operation is new Flyology.Operations.Operation with record
      Handle     : System.Address := System.Null_Address;
      Descriptor : Interfaces.C.int := Interfaces.C.int (-1);
      Result     : Long_Long_Integer := 0;
      Panicked   : Boolean := False;
   end record;

   overriding
   procedure Drive (Item : in out Future_Operation; Event : Flyology.Operations.Driver_Event);

   overriding
   procedure Request_Cancellation (Item : in out Future_Operation);
end Direct_Futures_Bridge;
