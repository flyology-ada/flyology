with Ada.Finalization;
with Flyology.Operations;
with Interfaces;
with System;

package Rust_Async_IO is

   Rust_IO_Error       : exception;
   Rust_Capacity_Error : exception;
   Rust_Engine_Busy    : exception;

   type Engine is limited private;

   procedure Initialize (Item : in out Engine);
   procedure Shutdown (Item : in out Engine);
   function Active_Jobs (Item : Engine) return Natural;
   function Active_Descriptors (Item : Engine) return Natural;

   type Byte_Array is array (Positive range <>) of Interfaces.Unsigned_8
   with Convention => C;

   type Progress is record
      Request_Writes  : Interfaces.Unsigned_32 := 0;
      Request_Reads   : Interfaces.Unsigned_32 := 0;
      Response_Writes : Interfaces.Unsigned_32 := 0;
      Response_Reads  : Interfaces.Unsigned_32 := 0;
   end record
   with Convention => C_Pass_By_Copy;

   type IO_Operation is new Flyology.Operations.Operation with private;

   function Start
     (Set                 :
        not null access Flyology.Operations.Completion_Set'Class;
      Runtime             : in out Engine;
      Input               : Byte_Array;
      Chunk_Size          : Positive;
      Step_Delay          : Duration := 0.0;
      Complete_Before_Arm : Boolean := False) return IO_Operation
   with Pre => Input'Length > 0 and then Input'Length <= 256;

   function Snapshot (Item : IO_Operation) return Progress;
   function Published_Before_Arm (Item : IO_Operation) return Boolean;

   procedure Finish
     (Item   : in out IO_Operation;
      Output : out Byte_Array;
      Length : out Natural)
   with Pre => Flyology.Operations.Is_Terminal (Item);

private
   type Engine is limited record
      Handle : System.Address := System.Null_Address;
   end record;

   type Job_Handle is record
      Generation : Interfaces.Unsigned_64 := 0;
      Slot       : Interfaces.Unsigned_32 := 0;
      Reserved   : Interfaces.Unsigned_32 := 0;
   end record
   with Convention => C_Pass_By_Copy;

   type Failure_Kind is (No_Failure, Signal_Failed, Bridge_Failed, IO_Failed);

   type Job_Lease is new Ada.Finalization.Limited_Controlled with record
      Runtime : System.Address := System.Null_Address;
      Handle  : Job_Handle;
      Owned   : Boolean := False;
   end record;

   overriding
   procedure Finalize (Item : in out Job_Lease);

   type IO_Operation is new Flyology.Operations.Operation with record
      Lease                : Job_Lease;
      Failure              : Failure_Kind := No_Failure;
      Was_Published_Before : Boolean := False;
   end record;

   overriding
   procedure Drive
     (Item : in out IO_Operation; Event : Flyology.Operations.Driver_Event);

   overriding
   procedure Request_Cancellation (Item : in out IO_Operation);

end Rust_Async_IO;
