with Flyology.Operations.Drivers;
with Interfaces.C;

package body Rust_Async_Jobs is
   use type Flyology.Operations.Driver_Event;
   use type Flyology.Operations.Terminal_Outcome;
   use type Interfaces.C.int;
   use type System.Address;

   Bridge_OK           : constant Interfaces.C.int := 0;
   State_Pending       : constant Interfaces.C.int := 0;
   State_Succeeded     : constant Interfaces.C.int := 1;
   State_Cancelled     : constant Interfaces.C.int := 2;
   State_Panicked      : constant Interfaces.C.int := 3;
   State_Signal_Failed : constant Interfaces.C.int := 4;

   function Rust_Engine_Create
     (Result : out System.Address) return Interfaces.C.int
   with
     Import,
     Convention    => C,
     External_Name => "flyology_rust_engine_create";

   function Rust_Engine_Destroy
     (Runtime : System.Address) return Interfaces.C.int
   with
     Import,
     Convention    => C,
     External_Name => "flyology_rust_engine_destroy";

   function Rust_Job_Start
     (Runtime   : System.Address;
      Mode      : Interfaces.C.int;
      Delay_MS  : Interfaces.Unsigned_64;
      Value     : Interfaces.Integer_64;
      Signal_FD : Interfaces.C.int;
      Result    : out Job_Handle) return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_rust_job_start";

   function Rust_Job_Poll
     (Runtime : System.Address;
      Handle  : Job_Handle;
      State   : out Interfaces.C.int;
      Value   : out Interfaces.Integer_64) return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_rust_job_poll";

   function Rust_Job_Cancel
     (Runtime : System.Address; Handle : Job_Handle) return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_rust_job_cancel";

   function Rust_Job_Release
     (Runtime : System.Address; Handle : Job_Handle) return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_rust_job_release";

   function Mode_Code (Mode : Job_Mode) return Interfaces.C.int
   is (case Mode is
         when Complete_Immediately => 0,
         when Complete_After_Delay => 1,
         when Panic_After_Delay    => 2);

   function Milliseconds (Value : Duration) return Interfaces.Unsigned_64 is
   begin
      if Value <= 0.0 then
         return 0;
      else
         return Interfaces.Unsigned_64 (Value * 1_000.0);
      end if;
   end Milliseconds;

   procedure Initialize (Item : in out Engine) is
      Status : Interfaces.C.int;
   begin
      if Item.Handle /= System.Null_Address then
         raise Program_Error with "Rust async engine is already initialized";
      end if;
      Status := Rust_Engine_Create (Item.Handle);
      if Status /= Bridge_OK or else Item.Handle = System.Null_Address then
         raise Rust_Job_Error
           with
             "Rust async engine initialization failed, status=" & Status'Image;
      end if;
   end Initialize;

   procedure Shutdown (Item : in out Engine) is
      Status : Interfaces.C.int;
   begin
      if Item.Handle = System.Null_Address then
         raise Program_Error with "Rust async engine is not initialized";
      end if;
      Status := Rust_Engine_Destroy (Item.Handle);
      if Status /= Bridge_OK then
         raise Rust_Job_Error
           with "Rust async engine shutdown failed, status=" & Status'Image;
      end if;
      Item.Handle := System.Null_Address;
   end Shutdown;

   procedure Rearm (Item : in out Job_Operation) is
      Read_Descriptor   : Interfaces.C.int;
      Signal_Descriptor : Interfaces.C.int;
   begin
      Flyology.Operations.Drivers.Completion_Source
        (Item, Read_Descriptor, Signal_Descriptor);
      pragma Assert (Signal_Descriptor >= 0);
      Flyology.Operations.Drivers.Arm_Readiness (Item, Read_Descriptor, False);
   end Rearm;

   procedure Observe (Item : in out Job_Operation) is
      State  : Interfaces.C.int;
      Value  : Interfaces.Integer_64;
      Status : Interfaces.C.int;
   begin
      Status := Rust_Job_Poll (Item.Runtime, Item.Handle, State, Value);
      if Status /= Bridge_OK then
         Item.Failure := Bridge_Failed;
         Flyology.Operations.Drivers.Complete
           (Item, Flyology.Operations.Failed);
      elsif State = State_Pending then
         Rearm (Item);
      elsif State = State_Succeeded then
         Item.Result := Value;
         Flyology.Operations.Drivers.Complete
           (Item, Flyology.Operations.Succeeded);
      elsif State = State_Cancelled then
         Flyology.Operations.Drivers.Complete
           (Item, Flyology.Operations.Cancelled);
      elsif State = State_Panicked then
         Item.Failure := Rust_Panicked;
         Flyology.Operations.Drivers.Complete
           (Item, Flyology.Operations.Failed);
      elsif State = State_Signal_Failed then
         Item.Failure := Signal_Failed;
         Flyology.Operations.Drivers.Complete
           (Item, Flyology.Operations.Failed);
      else
         Item.Failure := Bridge_Failed;
         Flyology.Operations.Drivers.Complete
           (Item, Flyology.Operations.Failed);
      end if;
   end Observe;

   function Start
     (Set       : not null access Flyology.Operations.Completion_Set'Class;
      Runtime   : in out Engine;
      Mode      : Job_Mode;
      Delay_For : Duration;
      Value     : Interfaces.Integer_64) return Job_Operation
   is
      Read_Descriptor   : Interfaces.C.int;
      Signal_Descriptor : Interfaces.C.int;
      Status            : Interfaces.C.int;
   begin
      if Runtime.Handle = System.Null_Address then
         raise Program_Error with "Rust async engine is not initialized";
      end if;
      return Result : Job_Operation (Set) do
         Result.Runtime := Runtime.Handle;
         Flyology.Operations.Drivers.Start (Result);
         Flyology.Operations.Drivers.Completion_Source
           (Result, Read_Descriptor, Signal_Descriptor);
         if Mode /= Complete_Immediately then
            Flyology.Operations.Drivers.Arm_Readiness
              (Result, Read_Descriptor, False);
         end if;
         Status :=
           Rust_Job_Start
             (Runtime.Handle,
              Mode_Code (Mode),
              Milliseconds (Delay_For),
              Value,
              Signal_Descriptor,
              Result.Handle);
         if Status /= Bridge_OK then
            Result.Failure := Bridge_Failed;
            Flyology.Operations.Drivers.Rollback_Start (Result);
            raise Rust_Job_Error
              with "Rust async job start failed, status=" & Status'Image;
         end if;
         if Mode = Complete_Immediately then
            --  Rust has already signalled. The nonblocking pipe retains that
            --  completion across this later arm.
            begin
               Flyology.Operations.Drivers.Arm_Readiness
                 (Result, Read_Descriptor, False);
            exception
               when others =>
                  Status := Rust_Job_Release (Result.Runtime, Result.Handle);
                  pragma Assert (Status = Bridge_OK);
                  Flyology.Operations.Drivers.Rollback_Start (Result);
                  raise;
            end;
         end if;
      end return;
   end Start;

   overriding
   procedure Drive
     (Item : in out Job_Operation; Event : Flyology.Operations.Driver_Event) is
   begin
      if Event /= Flyology.Operations.Source_Ready then
         Item.Failure := Bridge_Failed;
         Flyology.Operations.Drivers.Complete
           (Item, Flyology.Operations.Failed);
         return;
      end if;
      Observe (Item);
   exception
      when others =>
         Item.Failure := Bridge_Failed;
         Flyology.Operations.Drivers.Complete
           (Item, Flyology.Operations.Failed);
   end Drive;

   overriding
   procedure Request_Cancellation (Item : in out Job_Operation) is
      Status : Interfaces.C.int;
   begin
      Status := Rust_Job_Cancel (Item.Runtime, Item.Handle);
      if Status /= Bridge_OK then
         Item.Failure := Bridge_Failed;
         Flyology.Operations.Drivers.Complete
           (Item, Flyology.Operations.Failed);
      end if;
   --  A successful request leaves the existing readiness arm in place.
   --  Rust publishes cancellation only after the Tokio task stops using
   --  the job state, then signals that arm.
   exception
      when others =>
         Item.Failure := Bridge_Failed;
         Flyology.Operations.Drivers.Complete
           (Item, Flyology.Operations.Failed);
   end Request_Cancellation;

   procedure Finish
     (Item : in out Job_Operation; Value : out Interfaces.Integer_64)
   is
      Outcome : constant Flyology.Operations.Terminal_Outcome :=
        Flyology.Operations.Outcome (Item);
      Failure : constant Failure_Kind := Item.Failure;
      Status  : Interfaces.C.int;
   begin
      Status := Rust_Job_Release (Item.Runtime, Item.Handle);
      if Status /= Bridge_OK then
         raise Rust_Job_Error
           with "Rust async job release failed, status=" & Status'Image;
      end if;
      Value := Item.Result;
      Flyology.Operations.Consume (Item);
      if Outcome = Flyology.Operations.Cancelled then
         raise Flyology.Operations.Operation_Cancelled;
      elsif Outcome = Flyology.Operations.Failed then
         raise Rust_Job_Error with "Rust async job failed: " & Failure'Image;
      end if;
   end Finish;

end Rust_Async_Jobs;
