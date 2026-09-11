with Ada.Finalization;
with Ada.Unchecked_Deallocation;
with Flyology;
with Flyology.Observability;
with System;
with System.Storage_Elements;
with System.Storage_Pools;

procedure Lifecycle_Churn_Smoke is
   package Observation renames Flyology.Observability;

   use type Flyology.Observability.Counter;
   use type Flyology.Observability.Task_Instance_Id;
   use type System.Address;
   use type System.Storage_Elements.Storage_Offset;

   Churn_Count           : constant := 1_000;
   --  This test exercises deeper GNARL finalization paths, not the minimum
   --  stack contract. Keep 64 KiB as the representative small-stack class;
   --  Stack_Size_Parity_Smoke retains the separate 16 KiB coverage.
   Lifecycle_Stack_Bytes : constant := 64 * 1_024;
   type Boolean_Array is array (Positive range <>) of Boolean;

   protected State is
      procedure Ran (Index : Positive);
      procedure Finalized;
      procedure Waiting;
      entry Wait_Ran;
      entry Wait_Waiting;
      function Finalizations return Natural;
   private
      Seen           : Boolean_Array (1 .. Churn_Count) := (others => False);
      Run_Count      : Natural := 0;
      Finalize_Count : Natural := 0;
      Is_Waiting     : Boolean := False;
   end State;

   protected body State is
      procedure Ran (Index : Positive) is
      begin
         if Seen (Index) then
            raise Program_Error with "churn task ran more than once";
         end if;
         Seen (Index) := True;
         Run_Count := Run_Count + 1;
      end Ran;

      procedure Finalized is
      begin
         Finalize_Count := Finalize_Count + 1;
      end Finalized;

      procedure Waiting is
      begin
         Is_Waiting := True;
      end Waiting;

      entry Wait_Ran when Run_Count = Churn_Count is
      begin
         null;
      end Wait_Ran;

      entry Wait_Waiting when Is_Waiting is
      begin
         null;
      end Wait_Waiting;

      function Finalizations return Natural
      is (Finalize_Count);
   end State;

   type Finalization_Probe is new Ada.Finalization.Limited_Controlled
   with null record;

   overriding
   procedure Finalize (Item : in out Finalization_Probe) is
      pragma Unreferenced (Item);
   begin
      State.Finalized;
   end Finalize;

   task type Churn_Task (Index : Positive) is
      pragma Task_Info (Flyology.Lightweight_Task);
      pragma Storage_Size (Lifecycle_Stack_Bytes);
   end Churn_Task;

   task body Churn_Task is
      Probe : Finalization_Probe;
      pragma Unreferenced (Probe);
   begin
      State.Ran (Index);
   end Churn_Task;

   type Churn_Access is access Churn_Task;
   type Churn_Array is array (Positive range <>) of Churn_Access;
   procedure Free_Churn is new
     Ada.Unchecked_Deallocation (Churn_Task, Churn_Access);

   procedure Wait_For_Empty_Pool is
      Pool : Flyology.Observability.Stack_Pool_Snapshot;
   begin
      for Attempt in 1 .. 1_000 loop
         Pool := Flyology.Observability.Stack_Pool;
         exit when
           Pool.Live_Stacks = 0
           and then Pool.Active_Arenas = 0
           and then Pool.Reserved_Bytes = 0;
         delay 0.000_1;
      end loop;
      if Pool.Live_Stacks /= 0
        or else Pool.Active_Arenas /= 0
        or else Pool.Reserved_Bytes /= 0
      then
         raise Program_Error with "churn retained fiber stack state";
      end if;
   end Wait_For_Empty_Pool;

   procedure Wait_For_Finalizations (Target : Positive) is
   begin
      for Attempt in 1 .. 1_000 loop
         exit when State.Finalizations >= Target;
         delay 0.000_1;
      end loop;
      if State.Finalizations < Target then
         raise Program_Error with "task finalization was not observed";
      end if;
   end Wait_For_Finalizations;

   procedure Check_Normal_Churn is
      Items : Churn_Array (1 .. Churn_Count);
   begin
      for Index in Items'Range loop
         Items (Index) := new Churn_Task (Index);
      end loop;
      State.Wait_Ran;
      for Index in Items'Range loop
         while not Items (Index).all'Terminated loop
            delay 0.000_1;
         end loop;
         Free_Churn (Items (Index));
      end loop;
      Wait_For_Finalizations (Churn_Count);
      Wait_For_Empty_Pool;
   end Check_Normal_Churn;

   task type Exceptional_Task is
      pragma Task_Info (Flyology.Lightweight_Task);
      pragma Storage_Size (Lifecycle_Stack_Bytes);
   end Exceptional_Task;

   task body Exceptional_Task is
      Probe : Finalization_Probe;
      pragma Unreferenced (Probe);
   begin
      raise Constraint_Error with "expected unhandled task exception";
   end Exceptional_Task;

   type Exceptional_Access is access Exceptional_Task;
   procedure Free_Exceptional is new
     Ada.Unchecked_Deallocation (Exceptional_Task, Exceptional_Access);

   procedure Check_Unhandled_Exception is
      Item : Exceptional_Access := new Exceptional_Task;
   begin
      while not Item.all'Terminated loop
         delay 0.000_1;
      end loop;
      Free_Exceptional (Item);
      Wait_For_Finalizations (Churn_Count + 1);
      Wait_For_Empty_Pool;
   end Check_Unhandled_Exception;

   task type Abort_Task is
      pragma Task_Info (Flyology.Lightweight_Task);
      pragma Storage_Size (Lifecycle_Stack_Bytes);
   end Abort_Task;

   task body Abort_Task is
      Probe : Finalization_Probe;
      pragma Unreferenced (Probe);
   begin
      State.Waiting;
      delay 60.0;
   end Abort_Task;

   type Abort_Access is access Abort_Task;
   procedure Free_Abort is new
     Ada.Unchecked_Deallocation (Abort_Task, Abort_Access);

   procedure Check_Abort is
      Item : Abort_Access := new Abort_Task;
   begin
      State.Wait_Waiting;
      abort Item.all;
      while not Item.all'Terminated loop
         delay 0.000_1;
      end loop;
      Free_Abort (Item);
      Wait_For_Finalizations (Churn_Count + 2);
      Wait_For_Empty_Pool;
   end Check_Abort;

   task type Invalid_Group_Task with CPU => 128 is
      pragma Task_Info (Flyology.Lightweight_Task);
      pragma Storage_Size (Lifecycle_Stack_Bytes);
   end Invalid_Group_Task;

   task body Invalid_Group_Task is
   begin
      raise Program_Error with "invalid-group task body ran";
   end Invalid_Group_Task;

   procedure Check_Partial_Activation_Failure is
      Failed : Boolean := False;
   begin
      begin
         declare
            Item : Invalid_Group_Task;
            pragma Unreferenced (Item);
         begin
            raise Program_Error with "invalid group activated";
         end;
      exception
         when Tasking_Error =>
            Failed := True;
      end;
      if not Failed then
         raise Program_Error with "partial activation failure was not raised";
      end if;
      Wait_For_Empty_Pool;
   end Check_Partial_Activation_Failure;

   task type Instance_Task is
      pragma Task_Info (Flyology.Lightweight_Task);
      pragma Storage_Size (Lifecycle_Stack_Bytes);
   end Instance_Task;

   task body Instance_Task is
   begin
      null;
   end Instance_Task;

   package Storage renames System.Storage_Elements;
   package Storage_Pools renames System.Storage_Pools;

   Task_Object_Size : constant Storage.Storage_Count :=
     Instance_Task'Max_Size_In_Storage_Elements;
   Task_Alignment   : constant Storage.Storage_Count :=
     Storage.Storage_Count (Instance_Task'Alignment);
   Slot_Size        : constant Storage.Storage_Count :=
     Task_Object_Size + Task_Alignment - 1;

   type Single_Slot_Pool is new Storage_Pools.Root_Storage_Pool with record
      Bytes             : aliased Storage.Storage_Array (1 .. Slot_Size);
      In_Use            : Boolean := False;
      Allocated_Address : System.Address := System.Null_Address;
   end record;

   overriding
   procedure Allocate
     (Pool                     : in out Single_Slot_Pool;
      Storage_Address          : out System.Address;
      Size_In_Storage_Elements : Storage.Storage_Count;
      Alignment                : Storage.Storage_Count);

   overriding
   procedure Deallocate
     (Pool                     : in out Single_Slot_Pool;
      Storage_Address          : System.Address;
      Size_In_Storage_Elements : Storage.Storage_Count;
      Alignment                : Storage.Storage_Count);

   overriding
   function Storage_Size
     (Pool : Single_Slot_Pool) return Storage.Storage_Count;

   overriding
   procedure Allocate
     (Pool                     : in out Single_Slot_Pool;
      Storage_Address          : out System.Address;
      Size_In_Storage_Elements : Storage.Storage_Count;
      Alignment                : Storage.Storage_Count)
   is
      Remainder : Storage.Storage_Count;
      Padding   : Storage.Storage_Count;
   begin
      if Pool.In_Use
        or else Alignment = 0
        or else Alignment > Task_Alignment
        or else Size_In_Storage_Elements > Task_Object_Size
      then
         raise Storage_Error with "single task-object slot is unavailable";
      end if;

      Remainder := Pool.Bytes'Address mod Alignment;
      Padding := (if Remainder = 0 then 0 else Alignment - Remainder);
      Storage_Address := Pool.Bytes'Address + Padding;
      Pool.In_Use := True;
      Pool.Allocated_Address := Storage_Address;
   end Allocate;

   overriding
   procedure Deallocate
     (Pool                     : in out Single_Slot_Pool;
      Storage_Address          : System.Address;
      Size_In_Storage_Elements : Storage.Storage_Count;
      Alignment                : Storage.Storage_Count)
   is
      pragma Unreferenced (Size_In_Storage_Elements, Alignment);
   begin
      if not Pool.In_Use or else Storage_Address /= Pool.Allocated_Address then
         raise Program_Error
           with "single task-object slot deallocation mismatch";
      end if;
      Pool.In_Use := False;
      Pool.Allocated_Address := System.Null_Address;
   end Deallocate;

   overriding
   function Storage_Size (Pool : Single_Slot_Pool) return Storage.Storage_Count
   is (Pool.Bytes'Length);

   Instance_Pool : Single_Slot_Pool;

   type Instance_Access is access Instance_Task;
   for Instance_Access'Storage_Pool use Instance_Pool;
   procedure Free_Instance is new
     Ada.Unchecked_Deallocation (Instance_Task, Instance_Access);

   procedure Check_Task_Instances is
      type Instance_Array is
        array (Positive range <>) of Observation.Task_Instance_Id;

      Instances    : Instance_Array (1 .. Churn_Count) :=
        (others => Observation.No_Task_Instance);
      Items        : Observation.Task_Snapshot_Array (1 .. 1);
      Count        : Natural;
      Total        : Observation.Counter;
      Task_Address : System.Address := System.Null_Address;
   begin
      for Attempt in Instances'Range loop
         declare
            Item             : Instance_Access := new Instance_Task;
            Current_Address  : constant System.Address := Item.all'Address;
            Current_Instance : Observation.Task_Instance_Id;
         begin
            if Task_Address = System.Null_Address then
               Task_Address := Current_Address;
            elsif Current_Address /= Task_Address then
               raise Program_Error with "task-object address was not reused";
            end if;
            while not Item.all'Terminated loop
               delay 0.000_1;
            end loop;
            if not Observation.Snapshot_Tasks (0, Items, Count, Total)
              or else Count /= 1
              or else Total /= 1
            then
               raise Program_Error
                 with "finished task was not observable before deallocation";
            end if;
            Current_Instance := Items (1).Instance;
            if Current_Instance = Observation.No_Task_Instance then
               raise Program_Error with "task snapshot identity was zero";
            end if;
            for Prior in Instances'First .. Attempt - 1 loop
               if Current_Instance = Instances (Prior) then
                  raise Program_Error with "task snapshot identity was reused";
               end if;
            end loop;
            Instances (Attempt) := Current_Instance;
            Free_Instance (Item);
         end;
      end loop;
      Wait_For_Empty_Pool;
   end Check_Task_Instances;

begin
   Check_Normal_Churn;
   Check_Unhandled_Exception;
   Check_Abort;
   Check_Partial_Activation_Failure;
   Check_Task_Instances;
end Lifecycle_Churn_Smoke;
