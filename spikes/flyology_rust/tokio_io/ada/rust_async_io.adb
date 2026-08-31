with Flyology.Operations.Drivers;
with Interfaces.C;

package body Rust_Async_IO is
   use type Flyology.Operations.Driver_Event;
   use type Flyology.Operations.Terminal_Outcome;
   use type Interfaces.C.int;
   use type System.Address;

   Bridge_OK          : constant Interfaces.C.int := 0;
   Bridge_No_Capacity : constant Interfaces.C.int := 3;
   Bridge_Engine_Busy : constant Interfaces.C.int := 5;
   State_Pending      : constant Interfaces.C.int := 0;
   State_Succeeded    : constant Interfaces.C.int := 1;
   State_Cancelled    : constant Interfaces.C.int := 2;
   State_Signal_Error : constant Interfaces.C.int := 3;
   State_IO_Error     : constant Interfaces.C.int := 4;

   function Rust_Engine_Create
     (Result : out System.Address) return Interfaces.C.int
   with
     Import,
     Convention    => C,
     External_Name => "flyology_rust_io_engine_create";

   function Rust_Engine_Destroy
     (Runtime : System.Address) return Interfaces.C.int
   with
     Import,
     Convention    => C,
     External_Name => "flyology_rust_io_engine_destroy";

   function Rust_Engine_Count
     (Runtime : System.Address; Count : out Interfaces.Unsigned_32)
      return Interfaces.C.int
   with
     Import,
     Convention    => C,
     External_Name => "flyology_rust_io_engine_active_jobs";

   function Rust_Engine_Descriptor_Count
     (Runtime : System.Address; Count : out Interfaces.Unsigned_32)
      return Interfaces.C.int
   with
     Import,
     Convention    => C,
     External_Name => "flyology_rust_io_engine_active_descriptors";

   function Rust_IO_Start
     (Runtime    : System.Address;
      Input      : System.Address;
      Length     : Interfaces.Unsigned_32;
      Chunk_Size : Interfaces.Unsigned_32;
      Delay_MS   : Interfaces.Unsigned_64;
      Signal_FD  : Interfaces.C.int;
      Result     : out Job_Handle) return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_rust_io_start";

   function Rust_IO_Poll
     (Runtime : System.Address;
      Handle  : Job_Handle;
      State   : out Interfaces.C.int;
      Stats   : out Progress) return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_rust_io_poll";

   function Rust_IO_Copy_Result
     (Runtime  : System.Address;
      Handle   : Job_Handle;
      Output   : System.Address;
      Capacity : Interfaces.Unsigned_32;
      Length   : out Interfaces.Unsigned_32) return Interfaces.C.int
   with
     Import,
     Convention    => C,
     External_Name => "flyology_rust_io_copy_result";

   function Rust_IO_Cancel
     (Runtime : System.Address; Handle : Job_Handle) return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_rust_io_cancel";

   function Rust_IO_Release
     (Runtime : System.Address; Handle : Job_Handle) return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_rust_io_release";

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
         raise Program_Error with "Rust I/O engine is already initialized";
      end if;
      Status := Rust_Engine_Create (Item.Handle);
      if Status /= Bridge_OK or else Item.Handle = System.Null_Address then
         raise Rust_IO_Error with "Rust I/O engine create failed";
      end if;
   end Initialize;

   procedure Shutdown (Item : in out Engine) is
      Status : Interfaces.C.int;
   begin
      Status := Rust_Engine_Destroy (Item.Handle);
      if Status = Bridge_Engine_Busy then
         raise Rust_Engine_Busy
           with "Rust I/O engine still owns jobs or descriptors";
      elsif Status /= Bridge_OK then
         raise Rust_IO_Error with "Rust I/O engine destroy failed";
      end if;
      Item.Handle := System.Null_Address;
   end Shutdown;

   function Active_Jobs (Item : Engine) return Natural is
      Count  : Interfaces.Unsigned_32;
      Status : constant Interfaces.C.int :=
        Rust_Engine_Count (Item.Handle, Count);
   begin
      if Status /= Bridge_OK then
         raise Rust_IO_Error with "Rust I/O active-job query failed";
      end if;
      return Natural (Count);
   end Active_Jobs;

   function Active_Descriptors (Item : Engine) return Natural is
      Count  : Interfaces.Unsigned_32;
      Status : constant Interfaces.C.int :=
        Rust_Engine_Descriptor_Count (Item.Handle, Count);
   begin
      if Status /= Bridge_OK then
         raise Rust_IO_Error with "Rust I/O descriptor query failed";
      end if;
      return Natural (Count);
   end Active_Descriptors;

   overriding
   procedure Finalize (Item : in out Job_Lease) is
      Status : Interfaces.C.int;
   begin
      if Item.Owned then
         Status := Rust_IO_Release (Item.Runtime, Item.Handle);
         Item.Owned := False;
         pragma Assert (Status = Bridge_OK);
      end if;
   exception
      when others =>
         Item.Owned := False;
   end Finalize;

   procedure Rearm (Item : in out IO_Operation) is
      Read_Descriptor   : Interfaces.C.int;
      Signal_Descriptor : Interfaces.C.int;
   begin
      Flyology.Operations.Drivers.Completion_Source
        (Item, Read_Descriptor, Signal_Descriptor);
      pragma Assert (Signal_Descriptor >= 0);
      Flyology.Operations.Drivers.Arm_Readiness (Item, Read_Descriptor, False);
   end Rearm;

   procedure Observe (Item : in out IO_Operation) is
      State  : Interfaces.C.int;
      Stats  : Progress;
      Status : Interfaces.C.int;
   begin
      Status :=
        Rust_IO_Poll (Item.Lease.Runtime, Item.Lease.Handle, State, Stats);
      if Status /= Bridge_OK then
         Item.Failure := Bridge_Failed;
         Flyology.Operations.Drivers.Complete
           (Item, Flyology.Operations.Failed);
      elsif State = State_Pending then
         Rearm (Item);
      elsif State = State_Succeeded then
         Flyology.Operations.Drivers.Complete
           (Item, Flyology.Operations.Succeeded);
      elsif State = State_Cancelled then
         Flyology.Operations.Drivers.Complete
           (Item, Flyology.Operations.Cancelled);
      elsif State = State_Signal_Error then
         Item.Failure := Signal_Failed;
         Flyology.Operations.Drivers.Complete
           (Item, Flyology.Operations.Failed);
      elsif State = State_IO_Error then
         Item.Failure := IO_Failed;
         Flyology.Operations.Drivers.Complete
           (Item, Flyology.Operations.Failed);
      else
         Item.Failure := Bridge_Failed;
         Flyology.Operations.Drivers.Complete
           (Item, Flyology.Operations.Failed);
      end if;
   end Observe;

   function Start
     (Set                 :
        not null access Flyology.Operations.Completion_Set'Class;
      Runtime             : in out Engine;
      Input               : Byte_Array;
      Chunk_Size          : Positive;
      Step_Delay          : Duration := 0.0;
      Complete_Before_Arm : Boolean := False) return IO_Operation
   is
      Read_Descriptor   : Interfaces.C.int;
      Signal_Descriptor : Interfaces.C.int;
      State             : Interfaces.C.int;
      Stats             : Progress;
      Status            : Interfaces.C.int;
      Published         : Boolean := False;
   begin
      return Result : IO_Operation (Set) do
         Result.Lease.Runtime := Runtime.Handle;
         Flyology.Operations.Drivers.Start (Result);
         Flyology.Operations.Drivers.Completion_Source
           (Result, Read_Descriptor, Signal_Descriptor);
         if not Complete_Before_Arm then
            Flyology.Operations.Drivers.Arm_Readiness
              (Result, Read_Descriptor, False);
         end if;
         Status :=
           Rust_IO_Start
             (Runtime.Handle,
              Input (Input'First)'Address,
              Interfaces.Unsigned_32 (Input'Length),
              Interfaces.Unsigned_32 (Chunk_Size),
              Milliseconds (Step_Delay),
              Signal_Descriptor,
              Result.Lease.Handle);
         if Status /= Bridge_OK then
            Flyology.Operations.Drivers.Rollback_Start (Result);
            if Status = Bridge_No_Capacity then
               raise Rust_Capacity_Error
                 with "Rust I/O engine has no free slot";
            else
               raise Rust_IO_Error
                 with "Rust I/O start failed, status=" & Status'Image;
            end if;
         end if;
         Result.Lease.Owned := True;
         if Complete_Before_Arm then
            for Attempt in 1 .. 2_000 loop
               Status :=
                 Rust_IO_Poll
                   (Result.Lease.Runtime, Result.Lease.Handle, State, Stats);
               Published := Status = Bridge_OK and then State /= State_Pending;
               exit when Status /= Bridge_OK or else Published;
               delay 0.001;
            end loop;
            Result.Was_Published_Before := Published;
            Flyology.Operations.Drivers.Arm_Readiness
              (Result, Read_Descriptor, False);
         end if;
      end return;
   end Start;

   function Snapshot (Item : IO_Operation) return Progress is
      State  : Interfaces.C.int;
      Result : Progress;
      Status : constant Interfaces.C.int :=
        Rust_IO_Poll (Item.Lease.Runtime, Item.Lease.Handle, State, Result);
   begin
      if Status /= Bridge_OK then
         raise Rust_IO_Error with "Rust I/O snapshot failed";
      end if;
      return Result;
   end Snapshot;

   function Published_Before_Arm (Item : IO_Operation) return Boolean
   is (Item.Was_Published_Before);

   overriding
   procedure Drive
     (Item : in out IO_Operation; Event : Flyology.Operations.Driver_Event) is
   begin
      if Event /= Flyology.Operations.Source_Ready then
         Item.Failure := Bridge_Failed;
         Flyology.Operations.Drivers.Complete
           (Item, Flyology.Operations.Failed);
      else
         Observe (Item);
      end if;
   exception
      when others =>
         Item.Failure := Bridge_Failed;
         Flyology.Operations.Drivers.Complete
           (Item, Flyology.Operations.Failed);
   end Drive;

   overriding
   procedure Request_Cancellation (Item : in out IO_Operation) is
      Status : constant Interfaces.C.int :=
        Rust_IO_Cancel (Item.Lease.Runtime, Item.Lease.Handle);
   begin
      if Status /= Bridge_OK then
         Item.Failure := Bridge_Failed;
         Flyology.Operations.Drivers.Complete
           (Item, Flyology.Operations.Failed);
      end if;
   end Request_Cancellation;

   procedure Finish
     (Item   : in out IO_Operation;
      Output : out Byte_Array;
      Length : out Natural)
   is
      Outcome       : constant Flyology.Operations.Terminal_Outcome :=
        Flyology.Operations.Outcome (Item);
      Failure       : constant Failure_Kind := Item.Failure;
      Result_Length : Interfaces.Unsigned_32 := 0;
      Status        : Interfaces.C.int;
   begin
      if Outcome = Flyology.Operations.Succeeded then
         Status :=
           Rust_IO_Copy_Result
             (Item.Lease.Runtime,
              Item.Lease.Handle,
              Output (Output'First)'Address,
              Interfaces.Unsigned_32 (Output'Length),
              Result_Length);
         if Status /= Bridge_OK then
            raise Rust_IO_Error
              with "Rust I/O result copy failed, status=" & Status'Image;
         end if;
      end if;
      Status := Rust_IO_Release (Item.Lease.Runtime, Item.Lease.Handle);
      if Status /= Bridge_OK then
         raise Rust_IO_Error
           with "Rust I/O release failed, status=" & Status'Image;
      end if;
      Item.Lease.Owned := False;
      Length := Natural (Result_Length);
      Flyology.Operations.Consume (Item);
      if Outcome = Flyology.Operations.Cancelled then
         raise Flyology.Operations.Operation_Cancelled;
      elsif Outcome = Flyology.Operations.Failed then
         raise Rust_IO_Error with "Rust I/O failed: " & Failure'Image;
      end if;
   end Finish;

end Rust_Async_IO;
