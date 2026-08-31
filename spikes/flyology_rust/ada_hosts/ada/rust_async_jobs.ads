with Ada.Finalization;
with Flyology.Operations;
with Interfaces;
with System;

package Rust_Async_Jobs is

   Rust_Job_Error : exception;
   Rust_Capacity_Error : exception;
   Rust_Engine_Busy : exception;

   type Engine is limited private;

   procedure Initialize (Item : in out Engine);
   procedure Shutdown (Item : in out Engine);
   function Active_Jobs (Item : Engine) return Natural;

   type Job_Mode is
     (Complete_Immediately, Complete_After_Delay, Panic_After_Delay);

   type Job_Operation is new Flyology.Operations.Operation with private;

   function Start
     (Set       : not null access Flyology.Operations.Completion_Set'Class;
      Runtime   : in out Engine;
      Mode      : Job_Mode;
      Delay_For : Duration;
      Value     : Interfaces.Integer_64) return Job_Operation;

   procedure Finish
     (Item : in out Job_Operation; Value : out Interfaces.Integer_64)
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

   type Failure_Kind is
     (No_Failure, Rust_Panicked, Signal_Failed, Bridge_Failed);

   type Job_Lease is new Ada.Finalization.Limited_Controlled with record
      Runtime : System.Address := System.Null_Address;
      Handle  : Job_Handle;
      Owned   : Boolean := False;
   end record;

   overriding
   procedure Finalize (Item : in out Job_Lease);

   type Job_Operation is new Flyology.Operations.Operation with record
      Lease   : Job_Lease;
      Result  : Interfaces.Integer_64 := 0;
      Failure : Failure_Kind := No_Failure;
   end record;

   overriding
   procedure Drive
     (Item : in out Job_Operation; Event : Flyology.Operations.Driver_Event);

   overriding
   procedure Request_Cancellation (Item : in out Job_Operation);

end Rust_Async_Jobs;
