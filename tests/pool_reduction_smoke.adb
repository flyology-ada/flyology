with Flyology;
with Flyology.Execution_Groups;

procedure Pool_Reduction_Smoke is
   package Groups renames Flyology.Execution_Groups;

   use type Groups.Group_Id;
   use type Groups.Pool_Reduction_Phase;
   use type Groups.Pool_Reduction_Request_Result;

   Initial_Size : constant Groups.Loop_Pool_Size := 3;
   Target_Size  : constant Groups.Loop_Pool_Size := 1;

   protected Control is
      procedure Report_Initial (Number : Positive; Group : Groups.Group_Id);
      procedure Report_Explicit (Group : Groups.Group_Id);
      entry Wait_Initial;
      entry Hold_Group_One;
      entry Hold_Group_Two;
      procedure Release_Group_One;
      procedure Release_Group_Two;
      procedure Report_Group_One_Drained (Group : Groups.Group_Id);
      procedure Report_Group_Two_Pinned (Group : Groups.Group_Id);
      procedure Report_Group_Two_Drained (Group : Groups.Group_Id);
      entry Wait_Group_One_Drained;
      entry Wait_Group_Two_Pinned;
      entry Wait_Group_Two_Drained;
      entry Hold_Explicit;
      procedure Release_Explicit;
      procedure Report_Post_Cutover (Group : Groups.Group_Id);
      entry Wait_Post_Cutover;
      function Passed return Boolean;
   private
      Initial_Reports    : Natural := 0;
      Initial_OK         : Boolean := True;
      Explicit_Ready     : Boolean := False;
      Explicit_OK        : Boolean := False;
      Group_One_Released : Boolean := False;
      Group_Two_Released : Boolean := False;
      Explicit_Released  : Boolean := False;
      Group_One_Drained  : Boolean := False;
      Group_Two_Pinned   : Boolean := False;
      Group_Two_Drained  : Boolean := False;
      Post_Cutover_Done  : Boolean := False;
      Post_Cutover_OK    : Boolean := False;
   end Control;

   protected body Control is
      procedure Report_Initial (Number : Positive; Group : Groups.Group_Id) is
      begin
         Initial_Reports := Initial_Reports + 1;
         Initial_OK :=
           Initial_OK and then Number <= Integer (Initial_Size) and then Group = Groups.Group_Id (Number - 1);
      end Report_Initial;

      procedure Report_Explicit (Group : Groups.Group_Id) is
      begin
         Explicit_Ready := True;
         Explicit_OK := Group = 2;
      end Report_Explicit;

      entry Wait_Initial
        when Initial_Reports = Integer (Initial_Size)
        and Explicit_Ready
        and Hold_Group_One'Count = 1
        and Hold_Group_Two'Count = 1
        and Hold_Explicit'Count = 1
      is
      begin
         null;
      end Wait_Initial;

      entry Hold_Group_One when Group_One_Released is
      begin
         null;
      end Hold_Group_One;

      entry Hold_Group_Two when Group_Two_Released is
      begin
         null;
      end Hold_Group_Two;

      procedure Release_Group_One is
      begin
         Group_One_Released := True;
      end Release_Group_One;

      procedure Release_Group_Two is
      begin
         Group_Two_Released := True;
      end Release_Group_Two;

      procedure Report_Group_One_Drained (Group : Groups.Group_Id) is
      begin
         Group_One_Drained := Group = Groups.Default_Group;
      end Report_Group_One_Drained;

      procedure Report_Group_Two_Pinned (Group : Groups.Group_Id) is
      begin
         Group_Two_Pinned := Group = 2;
      end Report_Group_Two_Pinned;

      procedure Report_Group_Two_Drained (Group : Groups.Group_Id) is
      begin
         Group_Two_Drained := Group = Groups.Default_Group;
      end Report_Group_Two_Drained;

      entry Wait_Group_One_Drained when Group_One_Drained is
      begin
         null;
      end Wait_Group_One_Drained;

      entry Wait_Group_Two_Pinned when Group_Two_Pinned is
      begin
         null;
      end Wait_Group_Two_Pinned;

      entry Wait_Group_Two_Drained when Group_Two_Drained is
      begin
         null;
      end Wait_Group_Two_Drained;

      entry Hold_Explicit when Explicit_Released is
      begin
         null;
      end Hold_Explicit;

      procedure Release_Explicit is
      begin
         Explicit_Released := True;
      end Release_Explicit;

      procedure Report_Post_Cutover (Group : Groups.Group_Id) is
      begin
         Post_Cutover_Done := True;
         Post_Cutover_OK := Group = Groups.Default_Group;
      end Report_Post_Cutover;

      entry Wait_Post_Cutover when Post_Cutover_Done is
      begin
         null;
      end Wait_Post_Cutover;

      function Passed return Boolean
      is (Initial_OK
          and Explicit_OK
          and Group_One_Drained
          and Group_Two_Pinned
          and Group_Two_Drained
          and Post_Cutover_OK);
   end Control;

   task type Automatic_Worker (Number : Positive) is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Automatic_Worker;

   task body Automatic_Worker is
   begin
      if Number = 3 then
         declare
            Pin : Groups.Thread_Pin := Groups.Pin_To_Current_Thread;
            pragma Unreferenced (Pin);
         begin
            Control.Report_Initial (Number, Groups.Current);
            Control.Hold_Group_Two;
            Control.Report_Group_Two_Pinned (Groups.Current);
         end;
         delay 0.0;
         Control.Report_Group_Two_Drained (Groups.Current);
      else
         Control.Report_Initial (Number, Groups.Current);
         if Number = 2 then
            Control.Hold_Group_One;
            Control.Report_Group_One_Drained (Groups.Current);
         end if;
      end if;
   end Automatic_Worker;

   task Explicit_Worker
     with CPU => 2 is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Explicit_Worker;

   task body Explicit_Worker is
   begin
      Control.Report_Explicit (Groups.Current);
      Control.Hold_Explicit;
   end Explicit_Worker;

   task type Post_Cutover_Worker is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Post_Cutover_Worker;

   task body Post_Cutover_Worker is
   begin
      Control.Report_Post_Cutover (Groups.Current);
   end Post_Cutover_Worker;

   type Automatic_Access is access Automatic_Worker;
   type Post_Cutover_Access is access Post_Cutover_Worker;

   Status : Groups.Pool_Reduction_Status;
begin
   if Groups.Configured_Pool_Size /= Initial_Size then
      raise Program_Error with "unexpected initial pool size";
   end if;

   declare
      Workers : array (1 .. Integer (Initial_Size)) of Automatic_Access;
   begin
      for Number in Workers'Range loop
         Workers (Number) := new Automatic_Worker (Number);
      end loop;
      Control.Wait_Initial;

      if Groups.Request_Pool_Reduction (Target_Size) /= Groups.Reduction_Started
        or else Groups.Configured_Pool_Size /= Target_Size
      then
         raise Program_Error with "pool reduction did not start";
      end if;

      Status := Groups.Pool_Reduction;
      if Status.Phase /= Groups.Draining
        or else Status.Target_Size /= Target_Size
        or else Status.Automatic_Tasks /= 2
        or else Status.Pinned_Automatic_Tasks /= 1
        or else Status.Waiting_Automatic_Tasks /= 2
        or else Status.Explicit_Tasks /= 1
        or else Status.Placement_Claims /= 0
      then
         raise Program_Error with "initial reduction status is incorrect";
      end if;

      if Groups.Request_Pool_Reduction (Target_Size) /= Groups.Reduction_In_Progress then
         raise Program_Error with "concurrent reduction was not rejected";
      end if;

      begin
         Groups.Grow_Configured_Pool (Initial_Size);
         raise Program_Error with "growth during drainage was accepted";
      exception
         when Groups.Group_Error =>
            null;
      end;

      declare
         Post_Cutover : constant Post_Cutover_Access := new Post_Cutover_Worker;
         pragma Unreferenced (Post_Cutover);
      begin
         Control.Wait_Post_Cutover;
      end;

      Control.Release_Group_One;
      Control.Wait_Group_One_Drained;
      Status := Groups.Pool_Reduction;
      if Status.Phase /= Groups.Draining
        or else Status.Automatic_Tasks /= 1
        or else Status.Pinned_Automatic_Tasks /= 1
      then
         raise Program_Error with "unpinned task did not drain first";
      end if;

      Control.Release_Group_Two;
      Control.Wait_Group_Two_Pinned;
      Control.Wait_Group_Two_Drained;
      Status := Groups.Pool_Reduction;
      if Status.Phase /= Groups.Drained
        or else Status.Automatic_Tasks /= 0
        or else Status.Pinned_Automatic_Tasks /= 0
        or else Status.Waiting_Automatic_Tasks /= 0
        or else Status.Explicit_Tasks /= 1
      then
         raise Program_Error with "pool reduction did not drain";
      end if;

      Groups.Grow_Configured_Pool (Initial_Size);
      if Groups.Configured_Pool_Size /= Initial_Size
        or else Groups.Pool_Reduction.Phase /= Groups.No_Reduction
      then
         raise Program_Error with "pool did not grow after drainage";
      end if;

      if Groups.Request_Pool_Reduction (Target_Size) /= Groups.Reduction_Started
        or else Groups.Pool_Reduction.Phase /= Groups.Drained
      then
         raise Program_Error with "explicit task blocked empty reduction";
      end if;

      Control.Release_Explicit;
      pragma Unreferenced (Workers);
   end;

   if not Control.Passed then
      raise Program_Error with "pool reduction behavior failed";
   end if;
exception
   when others =>
      --  Do not let a failed assertion strand dependent workers behind their
      --  test gates and hide the original failure in task-master cleanup.
      Control.Release_Group_One;
      Control.Release_Group_Two;
      Control.Release_Explicit;
      raise;
end Pool_Reduction_Smoke;
