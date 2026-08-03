with Flyology;
with Flyology.Execution_Groups;
with Flyology.Execution_Groups.Topology;
with Flyology.IO;
with Flyology.Observability;
with Interfaces;

procedure Topology_Smoke is
   package Groups renames Flyology.Execution_Groups;
   package Topology renames Flyology.Execution_Groups.Topology;
   package Observe renames Flyology.Observability;

   use type Groups.Group_Id;

   Pool_Size : constant Groups.Loop_Pool_Size := 3;
   type Counts_Array is
     array
       (Topology.Shard_Id range
          0 .. Topology.Shard_Id (Pool_Size - 1)) of Natural;

   protected Results is
      procedure Native_Finished (Passed : Boolean);
      entry Wait_Native;
      procedure Lightweight_Finished (Passed : Boolean);
      entry Wait_Lightweight;
      function Passed return Boolean;
   private
      Native_Done      : Boolean := False;
      Lightweight_Done : Boolean := False;
      All_OK           : Boolean := True;
   end Results;

   protected body Results is
      procedure Native_Finished (Passed : Boolean) is
      begin
         All_OK := All_OK and Passed;
         Native_Done := True;
      end Native_Finished;

      entry Wait_Native when Native_Done is
      begin
         null;
      end Wait_Native;

      procedure Lightweight_Finished (Passed : Boolean) is
      begin
         All_OK := All_OK and Passed;
         Lightweight_Done := True;
      end Lightweight_Finished;

      entry Wait_Lightweight when Lightweight_Done is
      begin
         null;
      end Wait_Lightweight;

      function Passed return Boolean is (All_OK);
   end Results;

   task type Native_Caller is
      pragma Task_Info (Flyology.Native_Task);
   end Native_Caller;

   task body Native_Caller is
      Rejected : Boolean := False;
   begin
      begin
         Topology.Cross_To_Shard (0);
      exception
         when Groups.Migration_Error =>
            Rejected := True;
      end;
      Results.Native_Finished
        (Rejected
         and then Topology.Shard_For_Hash (4) = 1
         and then not Flyology.IO.Is_Lightweight_Task);
   exception
      when others =>
         Results.Native_Finished (False);
   end Native_Caller;

   task type Lightweight_Caller with CPU => 0 is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Lightweight_Caller;

   task body Lightweight_Caller is
      Outside_Rejected : Boolean := False;
      OK               : Boolean := Groups.Current = 0;
   begin
      Topology.Cross_To_Shard (Topology.Shard_For_Hash (2));
      OK := OK and Groups.Current = 2;

      begin
         Topology.Cross_To_Shard (Topology.Shard_Id (Pool_Size));
      exception
         when Groups.Migration_Error =>
            Outside_Rejected := True;
      end;
      OK := OK and Outside_Rejected and Groups.Current = 2;

      Topology.Cross_To_Shard (Topology.Shard_For_Hash (4));
      OK := OK and Groups.Current = 1;
      Results.Lightweight_Finished (OK);
   exception
      when others =>
         Results.Lightweight_Finished (False);
   end Lightweight_Caller;

   Counts   : Counts_Array := (others => 0);
   Snapshot : Observe.Group_Snapshot;
begin
   if Groups.Configured_Pool_Size /= Pool_Size then
      raise Program_Error with "unexpected topology test pool size";
   end if;

   if Topology.Shard_For_Hash (0, 1) /= 0
     or else Topology.Shard_For_Hash (Interfaces.Unsigned_64'Last, 128) /= 127
     or else Topology.Shard_For_Hash (0) /= 0
     or else Topology.Shard_For_Hash (1) /= 1
     or else Topology.Shard_For_Hash (2) /= 2
     or else Topology.Shard_For_Hash (3) /= 0
   then
      raise Program_Error with "topology hash boundary mapping failed";
   end if;

   for Hash in Interfaces.Unsigned_64 range 0 .. 299 loop
      Counts (Topology.Shard_For_Hash (Hash)) :=
        Counts (Topology.Shard_For_Hash (Hash)) + 1;
   end loop;
   for Count of Counts loop
      if Count /= 100 then
         raise Program_Error with "topology hash distribution failed";
      end if;
   end loop;

   --  Key selection and native rejection must not start event machinery.
   for Group in Groups.Group_Id range
     0 .. Groups.Group_Id (Pool_Size - 1)
   loop
      if Observe.Snapshot (Group, Snapshot) then
         raise Program_Error with "hash selection started an event loop";
      end if;
   end loop;

   declare
      Native : Native_Caller;
      pragma Unreferenced (Native);
   begin
      Results.Wait_Native;
   end;
   for Group in Groups.Group_Id range
     0 .. Groups.Group_Id (Pool_Size - 1)
   loop
      if Observe.Snapshot (Group, Snapshot) then
         raise Program_Error with "native crossing started an event loop";
      end if;
   end loop;

   declare
      Lightweight : Lightweight_Caller;
      pragma Unreferenced (Lightweight);
   begin
      Results.Wait_Lightweight;
   end;

   if not Results.Passed then
      raise Program_Error with "topology lane semantics failed";
   end if;
end Topology_Smoke;
