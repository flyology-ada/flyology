with Gnatevl;
with Gnatevl.Execution_Groups;
with Gnatevl.IO;
with Gnatevl.Observability;

procedure Loop_Pool_Smoke is
   package Groups renames Gnatevl.Execution_Groups;
   package Observe renames Gnatevl.Observability;

   use type Groups.Automatic_Placement_Policy;
   use type Groups.Group_Id;

   Worker_Count : constant := 6;
   Pool_Size    : constant := 3;
   type Group_Counts is
     array (Groups.Group_Id range 0 .. Pool_Size - 1) of Natural;

   protected Results is
      procedure Report_Native (Passed : Boolean);
      entry Wait_Native;
      procedure Report_Automatic (Group : Groups.Group_Id);
      procedure Report_Explicit (Passed : Boolean);
      procedure Report_Pin (Passed : Boolean);
      entry Wait_All;
      function Passed return Boolean;
   private
      Native_Done : Boolean := False;
      Native_OK   : Boolean := False;
      Reports     : Natural := 0;
      Counts      : Group_Counts := (others => 0);
      All_OK      : Boolean := True;
   end Results;

   protected body Results is
      procedure Report_Native (Passed : Boolean) is
      begin
         Native_OK := Passed;
         Native_Done := True;
      end Report_Native;

      entry Wait_Native when Native_Done is
      begin
         null;
      end Wait_Native;

      procedure Report_Automatic (Group : Groups.Group_Id) is
      begin
         Reports := Reports + 1;
         if Group <= Counts'Last then
            Counts (Group) := Counts (Group) + 1;
         else
            All_OK := False;
         end if;
      end Report_Automatic;

      procedure Report_Explicit (Passed : Boolean) is
      begin
         Reports := Reports + 1;
         All_OK := All_OK and Passed;
      end Report_Explicit;

      procedure Report_Pin (Passed : Boolean) is
      begin
         Reports := Reports + 1;
         All_OK := All_OK and Passed;
      end Report_Pin;

      entry Wait_All when Reports = Worker_Count + 3 is
      begin
         for Count of Counts loop
            All_OK := All_OK and Count = Worker_Count / Pool_Size;
         end loop;
      end Wait_All;

      function Passed return Boolean is (Native_OK and All_OK);
   end Results;

   task type Native_Worker with CPU => 1 is
      pragma Task_Info (Gnatevl.Native_Thread);
   end Native_Worker;

   task body Native_Worker is
      Current_Rejected : Boolean := False;
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
      Results.Report_Native
        (not Gnatevl.IO.Is_Evented_Task and then Current_Rejected);
   exception
      when others =>
         Results.Report_Native (False);
   end Native_Worker;

   task type Automatic_Worker is
      pragma Task_Info (Gnatevl.Event_Loop_Task);
   end Automatic_Worker;

   task body Automatic_Worker is
   begin
      Results.Report_Automatic (Groups.Current);
   exception
      when others =>
         Results.Report_Automatic (Groups.Group_Id'Last);
   end Automatic_Worker;

   task type Explicit_Worker with CPU => 2 is
      pragma Task_Info (Gnatevl.Event_Loop_Task);
   end Explicit_Worker;

   task body Explicit_Worker is
      task Inherited_Worker is
         pragma Task_Info (Gnatevl.Event_Loop_Task);
      end Inherited_Worker;

      task body Inherited_Worker is
      begin
         --  Ada D.16 inherits an activator's effective CPU when no aspect is
         --  present. Preserve that standard placement before applying the
         --  automatic policy to genuinely unassigned tasks.
         Results.Report_Explicit (Groups.Current = 2);
      exception
         when others =>
            Results.Report_Explicit (False);
      end Inherited_Worker;
   begin
      Results.Report_Explicit (Groups.Current = 2);
   exception
      when others =>
         Results.Report_Explicit (False);
   end Explicit_Worker;

   task type Pin_Worker is
      pragma Task_Info (Gnatevl.Event_Loop_Task);
   end Pin_Worker;

   task body Pin_Worker is
      Home      : Groups.Group_Id;
      Other     : Groups.Group_Id;
      Dedicated : Groups.Dedicated_Group_Id;
      Rejected  : Boolean := False;
      OK        : Boolean := True;
   begin
      Home := Groups.Current;
      Other := Groups.Group_Id ((Integer (Home) + 1) mod Pool_Size);
      declare
         Pin : Groups.Thread_Pin := Groups.Pin_To_Current_Thread;
         pragma Unreferenced (Pin);
      begin
         begin
            Groups.Migrate (Other);
         exception
            when Groups.Migration_Error =>
               Rejected := True;
         end;
      end;
      OK := OK and Rejected and Groups.Current = Home;

      Dedicated := Groups.Create_Dedicated;
      Groups.Migrate (Dedicated);
      OK := OK
        and Groups.Is_Dedicated (Groups.Current)
        and not Groups.In_Configured_Pool (Groups.Current);
      Groups.Migrate (Home);
      OK := OK and Groups.Current = Home;
      Results.Report_Pin (OK);
   exception
      when others =>
         Results.Report_Pin (False);
   end Pin_Worker;

   type Native_Access is access Native_Worker;
   type Automatic_Access is access Automatic_Worker;
   type Explicit_Access is access Explicit_Worker;
   type Pin_Access is access Pin_Worker;

   Snapshot : Observe.Group_Snapshot;
begin
   if Groups.Configured_Pool_Size /= Pool_Size then
      raise Program_Error with "unexpected loop-pool configuration";
   end if;
   case Groups.Configured_Placement is
      when Groups.Round_Robin =>
         null;
   end case;

   --  Configuration introspection must not start any of the configured loops.
   for Group in Groups.Group_Id range 0 .. Pool_Size - 1 loop
      if Observe.Snapshot (Group, Snapshot) then
         raise Program_Error with "pool introspection eagerly started a loop";
      end if;
   end loop;

   declare
      Native : constant Native_Access := new Native_Worker;
      pragma Unreferenced (Native);
   begin
      Results.Wait_Native;
   end;

   --  A native task, including one with an Ada CPU aspect, remains on stock
   --  GNARL and must not initialize the evented pool.
   for Group in Groups.Group_Id range 0 .. Pool_Size - 1 loop
      if Observe.Snapshot (Group, Snapshot) then
         raise Program_Error with "native CPU selection started an event loop";
      end if;
   end loop;

   declare
      Workers : array (1 .. Worker_Count) of Automatic_Access;
      Explicit : Explicit_Access;
      Pinned   : Pin_Access;
   begin
      for Index in Workers'Range loop
         Workers (Index) := new Automatic_Worker;
         if Index = Worker_Count / 2 then
            --  Explicit placement bypasses the automatic ticket; the six
            --  automatic tasks must still distribute two per configured loop.
            Explicit := new Explicit_Worker;
         end if;
      end loop;
      Pinned := new Pin_Worker;
      pragma Unreferenced (Workers, Explicit, Pinned);
      Results.Wait_All;
   end;

   if not Results.Passed then
      raise Program_Error with "event-loop pool placement failed";
   end if;

   for Group in Groups.Group_Id range 0 .. Pool_Size - 1 loop
      if not Observe.Snapshot (Group, Snapshot) then
         raise Program_Error with "configured loop was not created lazily";
      end if;
   end loop;
   if not Observe.Snapshot (2, Snapshot) then
      raise Program_Error with "explicit CPU group was not preserved";
   end if;
end Loop_Pool_Smoke;
