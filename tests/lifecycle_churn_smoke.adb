with Ada.Finalization;
with Ada.Unchecked_Deallocation;
with Flyology;
with Flyology.Observability;
with System;

procedure Lifecycle_Churn_Smoke is
   package Observation renames Flyology.Observability;

   use type Flyology.Observability.Counter;
   use type Flyology.Observability.Task_Instance_Id;
   use type System.Address;

   Churn_Count : constant := 1_000;
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

      function Finalizations return Natural is (Finalize_Count);
   end State;

   type Finalization_Probe is new Ada.Finalization.Limited_Controlled
     with null record;

   overriding procedure Finalize (Item : in out Finalization_Probe) is
      pragma Unreferenced (Item);
   begin
      State.Finalized;
   end Finalize;

   task type Churn_Task (Index : Positive) is
      pragma Task_Info (Flyology.Lightweight_Task);
      pragma Storage_Size (16 * 1_024);
   end Churn_Task;

   task body Churn_Task is
      Probe : Finalization_Probe;
      pragma Unreferenced (Probe);
   begin
      State.Ran (Index);
   end Churn_Task;

   type Churn_Access is access Churn_Task;
   type Churn_Array is array (Positive range <>) of Churn_Access;
   procedure Free_Churn is new Ada.Unchecked_Deallocation
     (Churn_Task, Churn_Access);

   procedure Wait_For_Empty_Pool is
      Pool : Flyology.Observability.Stack_Pool_Snapshot;
   begin
      for Attempt in 1 .. 1_000 loop
         Pool := Flyology.Observability.Stack_Pool;
         exit when Pool.Live_Stacks = 0
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
      pragma Storage_Size (16 * 1_024);
   end Exceptional_Task;

   task body Exceptional_Task is
      Probe : Finalization_Probe;
      pragma Unreferenced (Probe);
   begin
      raise Constraint_Error with "expected unhandled task exception";
   end Exceptional_Task;

   type Exceptional_Access is access Exceptional_Task;
   procedure Free_Exceptional is new Ada.Unchecked_Deallocation
     (Exceptional_Task, Exceptional_Access);

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
      pragma Storage_Size (16 * 1_024);
   end Abort_Task;

   task body Abort_Task is
      Probe : Finalization_Probe;
      pragma Unreferenced (Probe);
   begin
      State.Waiting;
      delay 60.0;
   end Abort_Task;

   type Abort_Access is access Abort_Task;
   procedure Free_Abort is new Ada.Unchecked_Deallocation
     (Abort_Task, Abort_Access);

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
      pragma Storage_Size (16 * 1_024);
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

   task type Address_Task is
      pragma Task_Info (Flyology.Lightweight_Task);
      pragma Storage_Size (16 * 1_024);
   end Address_Task;

   task body Address_Task is
   begin
      null;
   end Address_Task;

   type Address_Access is access Address_Task;
   procedure Free_Address is new Ada.Unchecked_Deallocation
     (Address_Task, Address_Access);

   procedure Check_Task_Address_Reuse is
      Previous          : System.Address := System.Null_Address;
      Previous_Instance : Observation.Task_Instance_Id :=
        Observation.No_Task_Instance;
      Items             : Observation.Task_Snapshot_Array (1 .. 1);
      Count             : Natural;
      Total             : Observation.Counter;
      Reused            : Boolean := False;
   begin
      for Attempt in 1 .. 1_000 loop
         declare
            Item : Address_Access := new Address_Task;
            Current : constant System.Address := Item.all'Address;
            Current_Instance : Observation.Task_Instance_Id;
         begin
            while not Item.all'Terminated loop
               delay 0.000_1;
            end loop;
            if not Observation.Snapshot_Tasks (0, Items, Count, Total)
              or else Count /= 1
              or else Total /= 1
            then
               raise Program_Error with
                 "finished task was not observable before deallocation";
            end if;
            Current_Instance := Items (1).Instance;
            if Current_Instance = Observation.No_Task_Instance then
               raise Program_Error with "task snapshot identity was zero";
            end if;
            if Current = Previous
              and then Current_Instance = Previous_Instance
            then
               raise Program_Error with
                 "task snapshot identity was reused with task address";
            end if;
            Free_Address (Item);
            Reused := Reused or else Current = Previous;
            Previous := Current;
            Previous_Instance := Current_Instance;
         end;
         exit when Reused;
      end loop;
      if not Reused then
         raise Program_Error with "task-address reuse was not exercised";
      end if;
      Wait_For_Empty_Pool;
   end Check_Task_Address_Reuse;

begin
   Check_Normal_Churn;
   Check_Unhandled_Exception;
   Check_Abort;
   Check_Partial_Activation_Failure;
   Check_Task_Address_Reuse;
end Lifecycle_Churn_Smoke;
