with Ada.Command_Line;
with Ada.Text_IO;
with Flyology;
with Flyology.Execution_Groups;
with Flyology.Execution_Groups.Topology;
with Interfaces;

procedure Thread_Per_Core is
   use Ada.Text_IO;

   package Groups renames Flyology.Execution_Groups;
   package Topology renames Flyology.Execution_Groups.Topology;

   use type Groups.Group_Id;

   Operations : constant Positive :=
     (if Ada.Command_Line.Argument_Count = 0
      then 1_000
      else Positive'Value (Ada.Command_Line.Argument (1)));
   Pool : constant Groups.Loop_Pool_Size := Groups.Configured_Pool_Size;

   protected Completion is
      procedure Finished (Passed : Boolean);
      entry Wait;
      function Passed return Boolean;
   private
      Finished_Count : Natural := 0;
      All_OK         : Boolean := True;
   end Completion;

   protected body Completion is
      procedure Finished (Passed : Boolean) is
      begin
         Finished_Count := Finished_Count + 1;
         All_OK := All_OK and Passed;
      end Finished;

      entry Wait when Finished_Count = 3 is
      begin
         null;
      end Wait;

      function Passed return Boolean is (All_OK);
   end Completion;

   task type Shard_Owner (Shard : Topology.Shard_Id) is
      pragma Task_Info (Flyology.Lightweight_Task);
      entry Apply
        (Hash     : Interfaces.Unsigned_64;
         Amount   : Positive;
         Accepted : out Boolean);
      entry Snapshot
        (Value     : out Natural;
         Group     : out Groups.Group_Id;
         Processor : out Integer);
      entry Stop;
   end Shard_Owner;

   task body Shard_Owner is
      Total : Natural := 0;
   begin
      Topology.Cross_To_Shard (Shard);
      loop
         select
            accept Apply
              (Hash     : Interfaces.Unsigned_64;
               Amount   : Positive;
               Accepted : out Boolean)
            do
               Accepted :=
                 Groups.Current = Shard
                 and then Topology.Shard_For_Hash (Hash) = Shard;
               if Accepted then
                  Total := Total + Amount;
               end if;
            end Apply;
         or
            accept Snapshot
              (Value     : out Natural;
               Group     : out Groups.Group_Id;
               Processor : out Integer)
            do
               Value := Total;
               Group := Groups.Current;
               Processor := Groups.Current_Processor;
            end Snapshot;
         or
            accept Stop;
            exit;
         end select;
      end loop;
   end Shard_Owner;

   type Owner_Access is access Shard_Owner;
   type Owner_Array is
     array (Topology.Shard_Id range <>) of Owner_Access;
   Owners : Owner_Array (0 .. Topology.Shard_Id (Pool - 1));

   procedure Stop_Owners is
   begin
      for Shard in Owners'Range loop
         if Owners (Shard) /= null then
            begin
               Owners (Shard).Stop;
            exception
               when Tasking_Error =>
                  null;
            end;
         end if;
      end loop;
   end Stop_Owners;

begin
   if Ada.Command_Line.Argument_Count > 1 then
      raise Constraint_Error with "usage: thread_per_core [OPERATIONS]";
   end if;

   for Shard in Owners'Range loop
      Owners (Shard) := new Shard_Owner (Shard);
   end loop;

   declare
      task Native_Client is
         pragma Task_Info (Flyology.Native_Task);
      end Native_Client;

      task body Native_Client is
         Accepted         : Boolean;
         Current_Rejected : Boolean := False;
         OK               : Boolean := True;
      begin
         begin
            declare
               Unexpected : constant Groups.Group_Id := Groups.Current;
               pragma Unreferenced (Unexpected);
            begin
               null;
            end;
         exception
            when Groups.Group_Error =>
               Current_Rejected := True;
         end;
         for Key in Natural range 0 .. Operations - 1 loop
            declare
               Hash   : constant Interfaces.Unsigned_64 :=
                 Interfaces.Unsigned_64 (Key);
               Target : constant Topology.Shard_Id :=
                 Topology.Shard_For_Hash (Hash);
            begin
               Owners (Target).Apply (Hash, 1, Accepted);
               OK := OK and Accepted;
            end;
         end loop;
         Completion.Finished (OK and Current_Rejected);
      exception
         when others =>
            Completion.Finished (False);
      end Native_Client;

      task Lightweight_Client with CPU => 0 is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Lightweight_Client;

      task body Lightweight_Client is
         Accepted : Boolean;
         OK       : Boolean := Groups.Current = 0;
      begin
         for Key in Natural range 0 .. Operations - 1 loop
            declare
               Hash   : constant Interfaces.Unsigned_64 :=
                 Interfaces.Unsigned_64 (Key);
               Target : constant Topology.Shard_Id :=
                 Topology.Shard_For_Hash (Hash);
            begin
               Owners (Target).Apply (Hash, 2, Accepted);
               OK := OK and Accepted;
            end;
         end loop;
         Completion.Finished (OK);
      exception
         when others =>
            Completion.Finished (False);
      end Lightweight_Client;

      task Crossing_Client with CPU => 0 is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Crossing_Client;

      task body Crossing_Client is
         Accepted : Boolean;
         OK       : Boolean := True;
      begin
         for Target in Owners'Range loop
            Topology.Cross_To_Shard (Target);
            OK := OK and Groups.Current = Target;
            Owners (Target).Apply
              (Interfaces.Unsigned_64 (Target), 3, Accepted);
            OK := OK and Accepted;
         end loop;
         Completion.Finished (OK);
      exception
         when others =>
            Completion.Finished (False);
      end Crossing_Client;
   begin
      Completion.Wait;
   end;

   if not Completion.Passed then
      raise Program_Error with "thread-per-core message routing failed";
   end if;

   Put_Line
     ("configured_shards=" & Groups.Loop_Pool_Size'Image (Pool)
      & " operations_per_client=" & Positive'Image (Operations));
   Put_Line
     ("native and lightweight callers routed keys to task-owned shard state;");
   Put_Line
     ("one lightweight caller also crossed each shard at an explicit "
      & "safe point.");

   declare
      Grand_Total : Natural := 0;
   begin
      for Shard in Owners'Range loop
         declare
            Value     : Natural;
            Group     : Groups.Group_Id;
            Processor : Integer;
         begin
            Owners (Shard).Snapshot (Value, Group, Processor);
            if Group /= Shard then
               raise Program_Error with "shard owner moved unexpectedly";
            end if;
            Grand_Total := Grand_Total + Value;
            Put_Line
              ("  shard=" & Topology.Shard_Id'Image (Shard)
               & " value=" & Natural'Image (Value)
               & " logical_processor=" & Integer'Image (Processor));
         end;
      end loop;
      if Grand_Total /= 3 * Operations + 3 * Natural (Pool) then
         raise Program_Error with "shard totals do not match submitted work";
      end if;
      Put_Line ("grand_total=" & Natural'Image (Grand_Total));
   end;

   Stop_Owners;
exception
   when Constraint_Error =>
      Stop_Owners;
      Put_Line ("usage: thread_per_core [OPERATIONS]");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   when others =>
      Stop_Owners;
      raise;
end Thread_Per_Core;
