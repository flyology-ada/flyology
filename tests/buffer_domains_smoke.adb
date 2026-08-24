with Ada.Finalization;
with Ada.Streams;
with Flyology.Buffers;
with Flyology.Buffers.Domains;
with Flyology.Buffers.Domains.Drivers;
with Flyology.Buffers.Domains.Testing;
with Interfaces;
with System;

procedure Buffer_Domains_Smoke is
   package Buffers renames Flyology.Buffers;
   package Domains renames Flyology.Buffers.Domains;
   package Drivers renames Flyology.Buffers.Domains.Drivers;
   package Testing renames Flyology.Buffers.Domains.Testing;

   use type Ada.Streams.Stream_Element_Array;
   use type Ada.Streams.Stream_Element_Offset;
   use type Buffers.Pool_Snapshot;
   use type Domains.Pool_Reference;
   use type Interfaces.Unsigned_64;
   use type System.Address;

   Configuration : constant Domains.Pool_Configuration_Array (3 .. 4) :=
     [3 => (Block_Size => 8, Capacity => 2),
      4 => (Block_Size => 32, Capacity => 3)];

   Domain_A : aliased Domains.Buffer_Domain := Domains.Create (Configuration);
   Domain_B : aliased Domains.Buffer_Domain := Domains.Create (Configuration);

   Small_A : constant Domains.Pool_Reference := Domains.Pool_At (Domain_A, 1);
   Large_A : constant Domains.Pool_Reference := Domains.Pool_At (Domain_A, 2);
   Small_B : constant Domains.Pool_Reference := Domains.Pool_At (Domain_B, 1);

   type Capability_Array is array (Positive range <>) of aliased Drivers.Buffer_Capability;

   type Capability_Owner
     (Domain   : not null access Domains.Buffer_Domain;
      Capacity : Positive)
   is limited new Ada.Finalization.Limited_Controlled with record
      Items : Capability_Array (1 .. Capacity);
   end record;

   overriding
   procedure Finalize (Owner : in out Capability_Owner) is
   begin
      for Index in Owner.Items'Range loop
         Drivers.Release (Owner.Domain, Owner.Items (Index));
      end loop;
   end Finalize;

   procedure Assert (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Assert;

   procedure Run_Heterogeneous_Ownership is
      Source       : Domains.Owned_Buffer (Domain_A'Access);
      Target       : Domains.Owned_Buffer (Domain_A'Access);
      Foreign      : Domains.Owned_Buffer (Domain_B'Access);
      First        : aliased Drivers.Buffer_Capability;
      Second       : aliased Drivers.Buffer_Capability;
      Before       : System.Address := System.Null_Address;
      During       : System.Address := System.Null_Address;
      After        : System.Address := System.Null_Address;
      Wrong_Domain : Boolean := False;
      Callback_Ran : Boolean := False;
      Callback_Raised : Boolean := False;

      procedure Remember_Before (Data : Ada.Streams.Stream_Element_Array) is
      begin
         Before := Data'Address;
      end Remember_Before;

      procedure Inspect_Capability (Data : Ada.Streams.Stream_Element_Array) is
      begin
         During := Data'Address;
         Assert (Data = [10, 20, 30, 40], "capability payload changed");
      end Inspect_Capability;

      procedure Remember_After (Data : Ada.Streams.Stream_Element_Array) is
      begin
         After := Data'Address;
         Assert (Data = [10, 20, 30, 40], "restored payload changed");
      end Remember_After;

      procedure Raise_From_Callback (Data : Ada.Streams.Stream_Element_Array) is
         pragma Unreferenced (Data);
      begin
         Callback_Ran := True;
         raise Constraint_Error with "expected callback failure";
      end Raise_From_Callback;
   begin
      Assert (Domains.Pool_Count (Domain_A) = 2, "domain pool count is wrong");
      Assert
        (not Domains.Is_Valid (Domains.Invalid_Pool) and then Domains.Is_Valid (Small_A),
         "pool reference validity classification is wrong");
      Assert
        (Domains.Block_Size (Domain_A, Small_A) = 8
         and then Domains.Capacity (Domain_A, Small_A) = 2,
         "small pool configuration is wrong");
      Assert
        (Domains.Block_Size (Domain_A, Large_A) = 32
         and then Domains.Capacity (Domain_A, Large_A) = 3,
         "large pool configuration is wrong");
      Assert
        (not Domains.Belongs_To (Domain_B, Small_A)
         and then Domains.Belongs_To (Domain_B, Small_B),
         "same-shaped domains were not distinguished");

      Domains.Acquire (Source, Small_A);
      Domains.Copy_From (Source, [10, 20, 30, 40]);
      Domains.Set_Tag (Source, 42);
      Domains.With_Readable_Data (Source, Remember_Before'Access);
      Drivers.Move_From (Domain_A'Access, Source, First);
      Assert
        (not Domains.Has_Buffer (Source) and then Drivers.Belongs_To (Domain_A'Access, First),
         "move into capability lost ownership");
      Assert
        (Drivers.Buffer_Pool (Domain_A'Access, First) = Small_A
         and then Drivers.Length (Domain_A'Access, First) = 4
         and then Drivers.Capacity (Domain_A'Access, First) = 8,
         "capability identity or size metadata is wrong");

      Wrong_Domain := False;
      begin
         declare
            Ignored : constant Natural := Drivers.Length (Domain_B'Access, First);
            pragma Unreferenced (Ignored);
         begin
            null;
         end;
      exception
         when Program_Error =>
            Wrong_Domain := True;
      end;
      Assert
        (Wrong_Domain
         and then Drivers.Belongs_To (Domain_A'Access, First)
         and then Domains.Current (Domain_A, Small_A) = (Available => 1, Outstanding => 1),
         "foreign capability query mutated ownership");

      Wrong_Domain := False;
      begin
         Drivers.Release (Domain_B'Access, First);
      exception
         when Program_Error =>
            Wrong_Domain := True;
      end;
      Assert
        (Wrong_Domain and then Drivers.Belongs_To (Domain_A'Access, First),
         "wrong-domain release mutated capability");
      Assert
        (Domains.Current (Domain_A, Small_A) = (Available => 1, Outstanding => 1)
         and then Domains.Current (Domain_B, Small_B) = (Available => 2, Outstanding => 0),
         "wrong-domain release changed pool accounting");

      Wrong_Domain := False;
      begin
         Drivers.Move_To (Domain_B'Access, First, Foreign);
      exception
         when Program_Error =>
            Wrong_Domain := True;
      end;
      Assert
        (Wrong_Domain
         and then Drivers.Has_Buffer (First)
         and then not Domains.Has_Buffer (Foreign),
         "wrong-domain move changed an owner");

      begin
         Drivers.With_Readable_Data (Domain_A'Access, First, Raise_From_Callback'Access);
      exception
         when Constraint_Error =>
            Callback_Raised := True;
      end;
      Assert
        (Callback_Ran and then Callback_Raised and then Drivers.Has_Buffer (First),
         "callback failure did not propagate while retaining the capability");

      Drivers.With_Readable_Data (Domain_A'Access, First, Inspect_Capability'Access);
      Drivers.Move (Domain_A'Access, First, Second);
      Assert
        (not Drivers.Has_Buffer (First) and then Drivers.Has_Buffer (Second),
         "capability move duplicated or lost ownership");
      Drivers.Move_To (Domain_A'Access, Second, Target);
      Domains.With_Readable_Data (Target, Remember_After'Access);
      Assert (Before = During and then During = After, "capability move copied payload storage");
      Assert (Domains.Tag (Target) = 42, "capability move lost application tag");
      Domains.Release (Target);

      Domains.Acquire (Source, Large_A);
      Assert (Domains.Buffer_Capacity (Source) = 32, "heterogeneous acquisition chose wrong pool");
      Domains.Release (Source);
   end Run_Heterogeneous_Ownership;

   procedure Run_Public_Move is
      Source : Domains.Owned_Buffer (Domain_A'Access);
      Target : Domains.Owned_Buffer (Domain_A'Access);
   begin
      Domains.Acquire (Source, Small_A);
      Domains.Copy_From (Source, [1, 2]);
      Domains.Move (Source, Target);
      Assert
        (not Domains.Has_Buffer (Source)
         and then Domains.Has_Buffer (Target)
         and then Domains.Buffer_Pool (Target) = Small_A,
         "public domain move failed");
      Domains.Release (Target);
   end Run_Public_Move;

   procedure Run_Wrong_Domain_Matrix is
      Source       : Domains.Owned_Buffer (Domain_A'Access);
      Foreign      : Domains.Owned_Buffer (Domain_B'Access);
      First        : aliased Drivers.Buffer_Capability;
      Second       : Drivers.Buffer_Capability;
      Wrong_Domain : Boolean;

      procedure Check_Payload (Data : Ada.Streams.Stream_Element_Array) is
      begin
         Assert (Data = [5, 6], "wrong-domain operation changed payload content");
      end Check_Payload;
   begin
      Wrong_Domain := False;
      begin
         Domains.Acquire (Source, Small_B);
      exception
         when Program_Error =>
            Wrong_Domain := True;
      end;
      Assert
        (Wrong_Domain and then not Domains.Has_Buffer (Source),
         "foreign pool reference acquisition changed target");
      Assert
        (Domains.Current (Domain_A, Small_A) = (Available => 2, Outstanding => 0)
         and then Domains.Current (Domain_B, Small_B) = (Available => 2, Outstanding => 0),
         "foreign pool reference acquisition changed accounting");

      Domains.Acquire (Source, Small_A);
      Domains.Copy_From (Source, [5, 6]);

      Wrong_Domain := False;
      begin
         Domains.Move (Source, Foreign);
      exception
         when Program_Error =>
            Wrong_Domain := True;
      end;
      Assert
        (Wrong_Domain
         and then Domains.Has_Buffer (Source)
         and then not Domains.Has_Buffer (Foreign),
         "cross-domain public move changed ownership");
      Domains.With_Readable_Data (Source, Check_Payload'Access);

      Wrong_Domain := False;
      begin
         Drivers.Move_From (Domain_B'Access, Source, First);
      exception
         when Program_Error =>
            Wrong_Domain := True;
      end;
      Assert
        (Wrong_Domain
         and then Domains.Has_Buffer (Source)
         and then not Drivers.Has_Buffer (First),
         "wrong-domain move-from changed ownership");
      Domains.With_Readable_Data (Source, Check_Payload'Access);

      Drivers.Move_From (Domain_A'Access, Source, First);
      Wrong_Domain := False;
      begin
         Drivers.Move (Domain_B'Access, First, Second);
      exception
         when Program_Error =>
            Wrong_Domain := True;
      end;
      Assert
        (Wrong_Domain
         and then Drivers.Has_Buffer (First)
         and then not Drivers.Has_Buffer (Second),
         "wrong-domain capability move changed ownership");
      Drivers.With_Readable_Data (Domain_A'Access, First, Check_Payload'Access);
      Drivers.Release (Domain_A'Access, First);

      Assert
        (Domains.Current (Domain_A, Small_A) = (Available => 2, Outstanding => 0)
         and then Domains.Current (Domain_B, Small_B) = (Available => 2, Outstanding => 0),
         "wrong-domain matrix changed pool accounting");
   end Run_Wrong_Domain_Matrix;

   procedure Run_Acquisition_And_Writes is
      First      : Domains.Owned_Buffer (Domain_A'Access);
      Second     : Domains.Owned_Buffer (Domain_A'Access);
      Third      : Domains.Owned_Buffer (Domain_A'Access);
      Acquired   : Boolean;
      Timed_Out  : Boolean := False;
      Too_Long   : Boolean := False;

      procedure Excessive_Length
        (Data : in out Ada.Streams.Stream_Element_Array; Length : in out Natural)
      is
         pragma Unreferenced (Data);
      begin
         Length := 33;
      end Excessive_Length;

      procedure Write_Five
        (Data : in out Ada.Streams.Stream_Element_Array; Length : in out Natural)
      is
      begin
         Data (Data'First .. Data'First + 4) := [11, 12, 13, 14, 15];
         Length := 5;
      end Write_Five;
   begin
      Domains.Try_Acquire (First, Small_A, Acquired);
      Assert (Acquired and then Domains.Has_Buffer (First), "domain try-acquire failed");
      Domains.Acquire (Second, Small_A);
      Domains.Try_Acquire (Third, Small_A, Acquired);
      Assert (not Acquired and then not Domains.Has_Buffer (Third), "exhausted try-acquire succeeded");
      begin
         Domains.Acquire_For (Third, Small_A, 0.01);
      exception
         when Buffers.Timeout_Error =>
            Timed_Out := True;
      end;
      Assert (Timed_Out and then not Domains.Has_Buffer (Third), "domain timed acquire did not time out");
      Domains.Release (First);
      Domains.Release (Second);

      Domains.Acquire_For (First, Large_A, 0.01);
      Domains.Copy_From (First, [1, 2, 3]);
      begin
         Domains.With_Writable_Data (First, Excessive_Length'Access);
      exception
         when Constraint_Error =>
            Too_Long := True;
      end;
      Assert (Too_Long and then Domains.Length (First) = 3, "excessive write length was committed");
      Domains.With_Writable_Data (First, Write_Five'Access);
      Assert (Domains.Length (First) = 5, "valid writable callback length was not committed");
      Domains.Release (First);
   end Run_Acquisition_And_Writes;

   procedure Run_Automatic_Finalization is
   begin
      declare
         Item : Domains.Owned_Buffer (Domain_A'Access);
      begin
         Domains.Acquire (Item, Small_A);
      end;
      Assert
        (Domains.Current (Domain_A, Small_A) = (Available => 2, Outstanding => 0),
         "domain-bound owner finalization did not release its slot");
   end Run_Automatic_Finalization;

   procedure Run_Capability_Owner_Finalization is
   begin
      declare
         Owner  : Capability_Owner (Domain_A'Access, Capacity => 2);
         Source : Domains.Owned_Buffer (Domain_A'Access);
      begin
         Domains.Acquire (Source, Small_A);
         Drivers.Move_From (Domain_A'Access, Source, Owner.Items (1));
      end;
      Assert
        (Domains.Current (Domain_A, Small_A) = (Available => 2, Outstanding => 0),
         "controlled capability-array owner did not release abandoned storage");
   end Run_Capability_Owner_Finalization;

   procedure Run_Domain_Finalization is
      Baseline : constant Natural := Testing.Live_Pools;
   begin
      declare
         Local : aliased Domains.Buffer_Domain := Domains.Create (Configuration);
         Item  : Domains.Owned_Buffer (Local'Access);
      begin
         Domains.Acquire (Item, Domains.Pool_At (Local, 1));
         Domains.Release (Item);
      end;
      Assert (Testing.Live_Pools = Baseline, "normal domain finalization leaked pool storage");
   end Run_Domain_Finalization;

   procedure Run_Transfer_Rollback is
      Source  : Domains.Owned_Buffer (Domain_A'Access);
      Target  : Domains.Owned_Buffer (Domain_A'Access);
      First   : aliased Drivers.Buffer_Capability;
      Second  : Drivers.Buffer_Capability;
      Injected : Boolean := False;
   begin
      Domains.Acquire (Source, Small_A);
      Domains.Copy_From (Source, [7, 8, 9]);
      Testing.Arm_Next_Transfer_Failure;
      begin
         Drivers.Move_From (Domain_A'Access, Source, First);
      exception
         when Program_Error =>
            Injected := True;
      end;
      Assert
        (Injected
         and then Domains.Has_Buffer (Source)
         and then not Drivers.Has_Buffer (First),
         "failed owner-to-capability move did not restore source");

      Drivers.Move_From (Domain_A'Access, Source, First);
      Injected := False;
      Testing.Arm_Next_Transfer_Failure;
      begin
         Drivers.Move (Domain_A'Access, First, Second);
      exception
         when Program_Error =>
            Injected := True;
      end;
      Assert
        (Injected
         and then Drivers.Has_Buffer (First)
         and then not Drivers.Has_Buffer (Second),
         "failed capability move did not restore source");

      Injected := False;
      Testing.Arm_Next_Transfer_Failure;
      begin
         Drivers.Move_To (Domain_A'Access, First, Target);
      exception
         when Program_Error =>
            Injected := True;
      end;
      Assert
        (Injected
         and then Drivers.Has_Buffer (First)
         and then not Domains.Has_Buffer (Target),
         "failed capability-to-owner move did not restore source");
      Drivers.Move_To (Domain_A'Access, First, Target);
      Domains.Release (Target);
   end Run_Transfer_Rollback;

   procedure Run_Construction_Rollback is
      Baseline : constant Natural := Testing.Live_Pools;
      Failed   : Boolean := False;
      Three    : constant Domains.Pool_Configuration_Array :=
        [(Block_Size => 4, Capacity => 1),
         (Block_Size => 8, Capacity => 1),
         (Block_Size => 16, Capacity => 1)];
   begin
      Testing.Arm_Allocation_Failure (After_Successful_Allocations => 1);
      begin
         declare
            Partial : Domains.Buffer_Domain := Domains.Create (Three);
            pragma Unreferenced (Partial);
         begin
            null;
         end;
      exception
         when Storage_Error =>
            Failed := True;
      end;
      Assert (Failed, "domain allocation failure was not injected");
      Assert (Testing.Live_Pools = Baseline, "partial domain construction leaked a pool");
   end Run_Construction_Rollback;

   procedure Run_Post_Commit_Failures is
      Source   : Domains.Owned_Buffer (Domain_A'Access);
      Target   : Domains.Owned_Buffer (Domain_A'Access);
      First    : aliased Drivers.Buffer_Capability;
      Second   : aliased Drivers.Buffer_Capability;
      Injected : Boolean;
   begin
      Domains.Acquire (Source, Small_A);
      Injected := False;
      Testing.Arm_Next_Transfer_Post_Commit_Failure;
      begin
         Domains.Move (Source, Target);
      exception
         when Program_Error =>
            Injected := True;
      end;
      Assert
        (Injected
         and then not Domains.Has_Buffer (Source)
         and then Domains.Has_Buffer (Target),
         "post-commit public move did not retain target ownership");
      Domains.Release (Target);

      Domains.Acquire (Source, Small_A);
      Injected := False;
      Testing.Arm_Next_Transfer_Post_Commit_Failure;
      begin
         Drivers.Move_From (Domain_A'Access, Source, First);
      exception
         when Program_Error =>
            Injected := True;
      end;
      Assert
        (Injected
         and then not Domains.Has_Buffer (Source)
         and then Drivers.Has_Buffer (First),
         "post-commit owner-to-capability move did not retain target ownership");
      Drivers.Release (Domain_A'Access, First);

      Domains.Acquire (Source, Small_A);
      Drivers.Move_From (Domain_A'Access, Source, First);
      Injected := False;
      Testing.Arm_Next_Transfer_Post_Commit_Failure;
      begin
         Drivers.Move (Domain_A'Access, First, Second);
      exception
         when Program_Error =>
            Injected := True;
      end;
      Assert
        (Injected
         and then not Drivers.Has_Buffer (First)
         and then Drivers.Has_Buffer (Second),
         "post-commit capability move did not retain target ownership");
      Drivers.Release (Domain_A'Access, Second);

      Domains.Acquire (Source, Small_A);
      Drivers.Move_From (Domain_A'Access, Source, First);
      Injected := False;
      Testing.Arm_Next_Transfer_Post_Commit_Failure;
      begin
         Drivers.Move_To (Domain_A'Access, First, Target);
      exception
         when Program_Error =>
            Injected := True;
      end;
      Assert
        (Injected
         and then not Drivers.Has_Buffer (First)
         and then Domains.Has_Buffer (Target),
         "post-commit capability-to-owner move did not retain target ownership");
      Domains.Release (Target);
   end Run_Post_Commit_Failures;

   procedure Run_Release_Rollback is
      Item       : Domains.Owned_Buffer (Domain_A'Access);
      Capability : aliased Drivers.Buffer_Capability;
      Injected   : Boolean := False;
   begin
      Domains.Acquire (Item, Small_A);
      Testing.Arm_Next_Release_Failure;
      begin
         Domains.Release (Item);
      exception
         when Program_Error =>
            Injected := True;
      end;
      Assert (Injected and then not Domains.Has_Buffer (Item), "failed release retained ownership");
      Assert
        (Domains.Current (Domain_A, Small_A) = (Available => 2, Outstanding => 0),
         "failed release did not restore pool capacity");

      Domains.Acquire (Item, Small_A);
      Injected := False;
      Testing.Arm_Next_Release_Post_Commit_Failure;
      begin
         Domains.Release (Item);
      exception
         when Program_Error =>
            Injected := True;
      end;
      Assert
        (Injected
         and then not Domains.Has_Buffer (Item)
         and then Domains.Current (Domain_A, Small_A) = (Available => 2, Outstanding => 0),
         "post-commit public release did not preserve sole release");

      Domains.Acquire (Item, Small_A);
      Drivers.Move_From (Domain_A'Access, Item, Capability);
      Injected := False;
      Testing.Arm_Next_Release_Failure;
      begin
         Drivers.Release (Domain_A'Access, Capability);
      exception
         when Program_Error =>
            Injected := True;
      end;
      Assert
        (Injected
         and then not Drivers.Has_Buffer (Capability)
         and then Domains.Current (Domain_A, Small_A) = (Available => 2, Outstanding => 0),
         "failed capability release did not restore capacity");

      Domains.Acquire (Item, Small_A);
      Drivers.Move_From (Domain_A'Access, Item, Capability);
      Injected := False;
      Testing.Arm_Next_Release_Post_Commit_Failure;
      begin
         Drivers.Release (Domain_A'Access, Capability);
      exception
         when Program_Error =>
            Injected := True;
      end;
      Assert
        (Injected
         and then not Drivers.Has_Buffer (Capability)
         and then Domains.Current (Domain_A, Small_A) = (Available => 2, Outstanding => 0),
         "post-commit capability release did not preserve sole release");
   end Run_Release_Rollback;

   procedure Run_Acquisition_Handoffs is
      Item     : Domains.Owned_Buffer (Domain_A'Access);
      Acquired : Boolean;
      Injected : Boolean;

      procedure Check_Pre_Commit (Message : String) is
      begin
         Assert
           (Injected
            and then not Domains.Has_Buffer (Item)
            and then Domains.Current (Domain_A, Small_A) = (Available => 2, Outstanding => 0),
            Message);
      end Check_Pre_Commit;

      procedure Check_Post_Commit (Message : String) is
      begin
         Assert
           (Injected
            and then Domains.Has_Buffer (Item)
            and then Domains.Current (Domain_A, Small_A) = (Available => 1, Outstanding => 1),
            Message);
         Domains.Release (Item);
      end Check_Post_Commit;
   begin
      Injected := False;
      Testing.Arm_Next_Acquisition_Pre_Commit_Failure;
      begin
         Domains.Acquire (Item, Small_A);
      exception
         when Program_Error =>
            Injected := True;
      end;
      Check_Pre_Commit ("pre-commit blocking acquisition leaked ownership");

      Injected := False;
      Testing.Arm_Next_Acquisition_Post_Commit_Failure;
      begin
         Domains.Acquire (Item, Small_A);
      exception
         when Program_Error =>
            Injected := True;
      end;
      Check_Post_Commit ("post-commit blocking acquisition lost ownership");

      Injected := False;
      Testing.Arm_Next_Acquisition_Pre_Commit_Failure;
      begin
         Domains.Try_Acquire (Item, Small_A, Acquired);
      exception
         when Program_Error =>
            Injected := True;
      end;
      Check_Pre_Commit ("pre-commit try-acquisition leaked ownership");

      Injected := False;
      Testing.Arm_Next_Acquisition_Post_Commit_Failure;
      begin
         Domains.Try_Acquire (Item, Small_A, Acquired);
      exception
         when Program_Error =>
            Injected := True;
      end;
      Check_Post_Commit ("post-commit try-acquisition lost ownership");

      Injected := False;
      Testing.Arm_Next_Acquisition_Pre_Commit_Failure;
      begin
         Domains.Acquire_For (Item, Small_A, 0.01);
      exception
         when Program_Error =>
            Injected := True;
      end;
      Check_Pre_Commit ("pre-commit timed acquisition leaked ownership");

      Injected := False;
      Testing.Arm_Next_Acquisition_Post_Commit_Failure;
      begin
         Domains.Acquire_For (Item, Small_A, 0.01);
      exception
         when Program_Error =>
            Injected := True;
      end;
      Check_Post_Commit ("post-commit timed acquisition lost ownership");
   end Run_Acquisition_Handoffs;

   procedure Run_Second_Slot_Slice is
      Local_Configuration : constant Domains.Pool_Configuration_Array :=
        [1 => (Block_Size => 8, Capacity => 2)];
      Local      : aliased Domains.Buffer_Domain := Domains.Create (Local_Configuration);
      Reference  : constant Domains.Pool_Reference := Domains.Pool_At (Local, 1);
      Held       : Domains.Owned_Buffer (Local'Access);
      Source     : Domains.Owned_Buffer (Local'Access);
      Target     : Domains.Owned_Buffer (Local'Access);
      Capability : aliased Drivers.Buffer_Capability;
      Before     : System.Address := System.Null_Address;
      During     : System.Address := System.Null_Address;
      After      : System.Address := System.Null_Address;

      procedure Observe_Before (Data : Ada.Streams.Stream_Element_Array) is
      begin
         Assert (Data'First = 9 and then Data = [31, 32, 33], "second-slot source slice is wrong");
         Before := Data'Address;
      end Observe_Before;

      procedure Observe_During (Data : Ada.Streams.Stream_Element_Array) is
      begin
         Assert (Data'First = 9 and then Data = [31, 32, 33], "second-slot capability slice is wrong");
         During := Data'Address;
      end Observe_During;

      procedure Observe_After (Data : Ada.Streams.Stream_Element_Array) is
      begin
         Assert (Data'First = 9 and then Data = [31, 32, 33], "second-slot target slice is wrong");
         After := Data'Address;
      end Observe_After;
   begin
      Domains.Acquire (Held, Reference);
      Domains.Acquire (Source, Reference);
      Domains.Copy_From (Source, [31, 32, 33]);
      Domains.With_Readable_Data (Source, Observe_Before'Access);
      Drivers.Move_From (Local'Access, Source, Capability);
      Drivers.With_Readable_Data (Local'Access, Capability, Observe_During'Access);
      Drivers.Move_To (Local'Access, Capability, Target);
      Domains.With_Readable_Data (Target, Observe_After'Access);
      Assert (Before = During and then During = After, "second-slot capability transfer copied payload");
      Domains.Release (Target);
      Domains.Release (Held);
   end Run_Second_Slot_Slice;

begin
   Run_Heterogeneous_Ownership;
   Run_Public_Move;
   Run_Wrong_Domain_Matrix;
   Run_Acquisition_And_Writes;
   Run_Automatic_Finalization;
   Run_Capability_Owner_Finalization;
   Run_Domain_Finalization;
   Run_Transfer_Rollback;
   Run_Construction_Rollback;
   Run_Post_Commit_Failures;
   Run_Release_Rollback;
   Run_Acquisition_Handoffs;
   Run_Second_Slot_Slice;
   Assert
     (Domains.Current (Domain_A, Small_A) = (Available => 2, Outstanding => 0)
      and then Domains.Current (Domain_A, Large_A) = (Available => 3, Outstanding => 0)
      and then Domains.Current (Domain_B, Small_B) = (Available => 2, Outstanding => 0),
      "domain tests did not restore all pool capacity");
end Buffer_Domains_Smoke;
