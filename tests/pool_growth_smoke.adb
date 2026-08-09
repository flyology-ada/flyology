with Flyology;
with Flyology.Execution_Groups;
with Flyology.Execution_Groups.Topology;
with Flyology.Observability;

procedure Pool_Growth_Smoke is
   package Groups renames Flyology.Execution_Groups;
   package Topology renames Flyology.Execution_Groups.Topology;
   package Observe renames Flyology.Observability;

   use type Groups.Group_Id;

   Initial_Size : constant Groups.Loop_Pool_Size := 3;
   Grown_Size   : constant Groups.Loop_Pool_Size := 7;
   type Group_Counts is
     array
       (Groups.Group_Id range 0 .. Groups.Group_Id (Grown_Size - 1))
       of Natural;

   protected Results is
      procedure Resident_Started (Passed : Boolean);
      entry Wait_Resident_Started;
      entry Await_Resident_Release;
      procedure Release_Resident;
      procedure Resident_Finished (Passed : Boolean);
      entry Wait_Resident_Finished;
      procedure Grower_Finished (Passed : Boolean);
      entry Wait_Growers;
      procedure Automatic_Finished (Group : Groups.Group_Id);
      entry Wait_Automatic;
      function Passed return Boolean;
   private
      Resident_Is_Started  : Boolean := False;
      Resident_Is_Released : Boolean := False;
      Resident_Is_Finished : Boolean := False;
      Grower_Count         : Natural := 0;
      Automatic_Count      : Natural := 0;
      Counts               : Group_Counts := (others => 0);
      All_OK               : Boolean := True;
   end Results;

   protected body Results is
      procedure Resident_Started (Passed : Boolean) is
      begin
         All_OK := All_OK and Passed;
         Resident_Is_Started := True;
      end Resident_Started;

      entry Wait_Resident_Started when Resident_Is_Started is
      begin
         null;
      end Wait_Resident_Started;

      entry Await_Resident_Release when Resident_Is_Released is
      begin
         null;
      end Await_Resident_Release;

      procedure Release_Resident is
      begin
         Resident_Is_Released := True;
      end Release_Resident;

      procedure Resident_Finished (Passed : Boolean) is
      begin
         All_OK := All_OK and Passed;
         Resident_Is_Finished := True;
      end Resident_Finished;

      entry Wait_Resident_Finished when Resident_Is_Finished is
      begin
         null;
      end Wait_Resident_Finished;

      procedure Grower_Finished (Passed : Boolean) is
      begin
         All_OK := All_OK and Passed;
         Grower_Count := Grower_Count + 1;
      end Grower_Finished;

      entry Wait_Growers when Grower_Count = 2 is
      begin
         null;
      end Wait_Growers;

      procedure Automatic_Finished (Group : Groups.Group_Id) is
      begin
         Automatic_Count := Automatic_Count + 1;
         if Group <= Counts'Last then
            Counts (Group) := Counts (Group) + 1;
         else
            All_OK := False;
         end if;
      end Automatic_Finished;

      entry Wait_Automatic when Automatic_Count = Natural (Grown_Size) is
      begin
         for Count of Counts loop
            All_OK := All_OK and Count = 1;
         end loop;
      end Wait_Automatic;

      function Passed return Boolean is (All_OK);
   end Results;

   task type Resident_Task is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Resident_Task;

   task body Resident_Task is
      Home : Groups.Group_Id;
   begin
      Home := Groups.Current;
      Results.Resident_Started (Home < Groups.Group_Id (Initial_Size));
      Results.Await_Resident_Release;
      Results.Resident_Finished (Groups.Current = Home);
   exception
      when others =>
         Results.Resident_Started (False);
         Results.Resident_Finished (False);
   end Resident_Task;

   task type Grower (Minimum_Size : Groups.Loop_Pool_Size) is
      pragma Task_Info (Flyology.Native_Task);
   end Grower;

   task body Grower is
   begin
      Groups.Grow_Configured_Pool (Minimum_Size);
      Results.Grower_Finished (True);
   exception
      when others =>
         Results.Grower_Finished (False);
   end Grower;

   task type Automatic_Worker is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Automatic_Worker;

   task body Automatic_Worker is
   begin
      Results.Automatic_Finished (Groups.Current);
   exception
      when others =>
         Results.Automatic_Finished (Groups.Group_Id'Last);
   end Automatic_Worker;

   type Resident_Access is access Resident_Task;
   type Automatic_Access is access Automatic_Worker;
   Snapshot : Observe.Group_Snapshot;
begin
   if Groups.Configured_Pool_Size /= Initial_Size then
      raise Program_Error with "unexpected initial pool size";
   end if;
   for Group in
     Groups.Group_Id range 0 .. Groups.Group_Id (Grown_Size - 1)
   loop
      if Observe.Snapshot (Group, Snapshot) then
         raise Program_Error with "pool-growth inspection started a loop";
      end if;
   end loop;

   declare
      Resident : constant Resident_Access := new Resident_Task;
      pragma Unreferenced (Resident);
   begin
      Results.Wait_Resident_Started;

      declare
         First  : Grower (6);
         Second : Grower (Grown_Size);
         pragma Unreferenced (First, Second);
      begin
         Results.Wait_Growers;
      end;

      if Groups.Configured_Pool_Size /= Grown_Size
        or else not Groups.In_Configured_Pool
          (Groups.Group_Id (Grown_Size - 1))
        or else Groups.In_Configured_Pool (Groups.Group_Id (Grown_Size))
        or else Topology.Shard_For_Hash (6) /= 6
        or else Topology.Shard_For_Hash (7) /= 0
      then
         raise Program_Error with "concurrent pool growth was not published";
      end if;

      Groups.Grow_Configured_Pool (Initial_Size);
      Groups.Grow_Configured_Pool (Grown_Size);
      if Groups.Configured_Pool_Size /= Grown_Size then
         raise Program_Error with "pool growth was not monotonic and idempotent";
      end if;

      for Group in
        Groups.Group_Id range
          Groups.Group_Id (Initial_Size) .. Groups.Group_Id (Grown_Size - 1)
      loop
         if Observe.Snapshot (Group, Snapshot) then
            raise Program_Error with "pool growth eagerly started a loop";
         end if;
      end loop;

      Results.Release_Resident;
      Results.Wait_Resident_Finished;

      declare
         Workers : array (1 .. Natural (Grown_Size)) of Automatic_Access;
      begin
         for Worker of Workers loop
            Worker := new Automatic_Worker;
         end loop;
         Results.Wait_Automatic;
      end;
   end;

   if not Results.Passed then
      raise Program_Error with "pool-growth task semantics failed";
   end if;

   for Group in
     Groups.Group_Id range 0 .. Groups.Group_Id (Grown_Size - 1)
   loop
      if not Observe.Snapshot (Group, Snapshot) then
         raise Program_Error with "grown pool did not place automatic work";
      end if;
   end loop;

   Groups.Grow_Configured_Pool (Groups.Loop_Pool_Size'Last);
   if Groups.Configured_Pool_Size /= Groups.Loop_Pool_Size'Last
     or else Observe.Snapshot (Groups.Shared_Group_Id'Last, Snapshot)
   then
      raise Program_Error with "maximum pool growth was not lazy";
   end if;
end Pool_Growth_Smoke;
