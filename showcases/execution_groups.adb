with Ada.Exceptions;
with Ada.Text_IO;
with Gnatevl;
with Gnatevl.Execution_Groups;
with Interfaces.C;
with Showcase_Support;

procedure Execution_Groups is
   package Groups renames Gnatevl.Execution_Groups;
   package C renames Interfaces.C;

   use type C.int;
   use type Groups.Group_Id;

   function C_Usleep (Microseconds : C.unsigned) return C.int;
   pragma Import (C, C_Usleep, "usleep");

   protected Demo is
      procedure Blocking_Started;
      entry Wait_For_Blocking;
      procedure Tick;
      entry Wait_For_Ticks;
   private
      Started : Boolean := False;
      Ticks   : Natural := 0;
   end Demo;

   protected body Demo is
      procedure Blocking_Started is
      begin
         Started := True;
      end Blocking_Started;

      entry Wait_For_Blocking when Started is
      begin
         null;
      end Wait_For_Blocking;

      procedure Tick is
      begin
         Ticks := Ticks + 1;
      end Tick;

      entry Wait_For_Ticks when Ticks = 5 is
      begin
         null;
      end Wait_For_Ticks;
   end Demo;

   protected Completion is
      procedure Finished (Passed : Boolean);
      entry Wait;
      function Passed return Boolean;
   private
      Count : Natural := 0;
      OK    : Boolean := True;
   end Completion;

   protected body Completion is
      procedure Finished (Passed : Boolean) is
      begin
         Count := Count + 1;
         OK := OK and Passed;
      end Finished;

      entry Wait when Count = 5 is
      begin
         null;
      end Wait;

      function Passed return Boolean is (OK);
   end Completion;

   procedure Show (Label : String) is
   begin
      Ada.Text_IO.Put_Line
        (Label
         & " group=" & Groups.Current'Image
         & " pthread=" & Showcase_Support.Thread_Image);
   end Show;

   task Group_One_Peer with CPU => 1 is
      pragma Task_Info (Gnatevl.Event_Loop_Task);
   end Group_One_Peer;

   task Group_Two_Peer with CPU => 2 is
      pragma Task_Info (Gnatevl.Event_Loop_Task);
   end Group_Two_Peer;

   task Heartbeat with CPU => 2 is
      pragma Task_Info (Gnatevl.Event_Loop_Task);
   end Heartbeat;

   task Migrator with CPU => 1 is
      pragma Task_Info (Gnatevl.Event_Loop_Task);
   end Migrator;
   task Native_Task is
      pragma Task_Info (Gnatevl.Native_Thread);
   end Native_Task;

   task body Group_One_Peer is
   begin
      Show ("CPU aspect peer A ");
      Completion.Finished (Groups.Current = Groups.For_CPU (1));
   exception
      when others =>
         Completion.Finished (False);
   end Group_One_Peer;

   task body Group_Two_Peer is
   begin
      Show ("CPU aspect peer B ");
      Completion.Finished (Groups.Current = Groups.For_CPU (2));
   exception
      when others =>
         Completion.Finished (False);
   end Group_Two_Peer;

   task body Heartbeat is
   begin
      Demo.Wait_For_Blocking;
      for Tick in 1 .. 5 loop
         delay 0.015;
         Demo.Tick;
         Ada.Text_IO.Put_Line
           ("shared loop stayed live: tick" & Tick'Image
            & " pthread=" & Showcase_Support.Thread_Image);
      end loop;
      Completion.Finished (Groups.Current = 2);
   exception
      when others =>
         Completion.Finished (False);
   end Heartbeat;

   task body Migrator is
      Dedicated : Groups.Dedicated_Group_Id;
      Result    : C.int;
      OK        : Boolean := True;
   begin
      Show ("migrator starts   ");
      OK := OK and Groups.Current = 1;

      Groups.Migrate (2);
      Show ("migrated 1 -> 2  ");
      OK := OK and Groups.Current = 2;

      Dedicated := Groups.Create_Dedicated;
      Groups.Migrate (Dedicated);
      Show ("dedicated lane   ");
      OK := OK and Groups.Is_Dedicated (Groups.Current);

      Ada.Text_IO.Put_Line
        ("dedicated lane performs a blocking 100 ms foreign call");
      Demo.Blocking_Started;
      Result := C_Usleep (100_000);
      OK := OK and Result = 0;
      Demo.Wait_For_Ticks;

      Groups.Migrate (1);
      Show ("returned to 1    ");
      OK := OK and Groups.Current = 1;
      Completion.Finished (OK);
   exception
      when Occurrence : others =>
         Demo.Blocking_Started;
         Ada.Text_IO.Put_Line
           ("migrator failed: "
            & Ada.Exceptions.Exception_Information (Occurrence));
         Completion.Finished (False);
   end Migrator;

   task body Native_Task is
      Rejected : Boolean := False;
   begin
      Ada.Text_IO.Put_Line
        ("stock Native_Thread pthread=" & Showcase_Support.Thread_Image);
      begin
         Groups.Migrate (Groups.Default_Group);
      exception
         when Groups.Migration_Error =>
            Rejected := True;
      end;
      Ada.Text_IO.Put_Line
        ("live stock-native conversion rejected (creation-time lane)");
      Completion.Finished (Rejected);
   exception
      when others =>
         Completion.Finished (False);
   end Native_Task;

begin
   Ada.Text_IO.Put_Line
     ("execution groups: CPU aspects choose shared loops; migration changes "
      & "loop threads");
   Completion.Wait;
   if not Completion.Passed then
      raise Program_Error with "execution-group showcase failed";
   end if;
   Ada.Text_IO.Put_Line
     ("shared groups, live migration, a dedicated thread, and native "
      & "boundaries all passed");
end Execution_Groups;
