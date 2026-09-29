with Flyology;
with Flyology.Execution_Groups;
with Flyology.IO;

procedure Task_CPU_Inheritance_Smoke is
   package Groups renames Flyology.Execution_Groups;

   use type Groups.Group_Id;

   Parent_Group : constant Groups.Group_Id := 100;

   protected Results is
      procedure Report_Lightweight_Child
        (Group : Groups.Group_Id; Is_Lightweight : Boolean);
      procedure Report_Native_Child (Is_Lightweight : Boolean);
      procedure Complete (Parent_OK : Boolean);
      procedure Fail;
      entry Wait;
      function Passed return Boolean;
   private
      Lightweight_OK : Boolean := False;
      Native_OK      : Boolean := False;
      Done           : Boolean := False;
      All_OK         : Boolean := False;
   end Results;

   protected body Results is
      procedure Report_Lightweight_Child
        (Group : Groups.Group_Id; Is_Lightweight : Boolean) is
      begin
         Lightweight_OK :=
           Is_Lightweight
           and then Group /= Parent_Group
           and then Groups.In_Configured_Pool (Group);
      end Report_Lightweight_Child;

      procedure Report_Native_Child (Is_Lightweight : Boolean) is
      begin
         Native_OK := not Is_Lightweight;
      end Report_Native_Child;

      procedure Complete (Parent_OK : Boolean) is
      begin
         All_OK := Parent_OK and Lightweight_OK and Native_OK;
         Done := True;
      end Complete;

      procedure Fail is
      begin
         All_OK := False;
         Done := True;
      end Fail;

      entry Wait when Done is
      begin
         null;
      end Wait;

      function Passed return Boolean
      is (All_OK);
   end Results;

   task Parent
     with CPU => 100 is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Parent;

   task body Parent is
   begin
      declare
         task Lightweight_Child is
            pragma Task_Info (Flyology.Lightweight_Task);
         end Lightweight_Child;

         task body Lightweight_Child is
         begin
            Results.Report_Lightweight_Child
              (Groups.Current, Flyology.IO.Is_Lightweight_Task);
         end Lightweight_Child;
      begin
         null;
      end;

      declare
         task Native_Child is
            pragma Task_Info (Flyology.Native_Task);
         end Native_Child;

         task body Native_Child is
         begin
            Results.Report_Native_Child (Flyology.IO.Is_Lightweight_Task);
         end Native_Child;
      begin
         null;
      end;

      Results.Complete (Groups.Current = Parent_Group);
   exception
      when others =>
         Results.Fail;
   end Parent;
begin
   Results.Wait;
   if not Results.Passed then
      raise Program_Error
        with
          "unspecified child inherited a lightweight creator's execution group";
   end if;
end Task_CPU_Inheritance_Smoke;
