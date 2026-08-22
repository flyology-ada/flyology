with Ada.Command_Line;
with Flyology;
with Flyology.IO;

procedure Default_Policy_Smoke is
   Expected_Lightweight : constant Boolean :=
     Ada.Command_Line.Argument_Count = 1 and then Ada.Command_Line.Argument (1) = "lightweight";

   protected Results is
      procedure Report (Lightweight : Boolean);
      entry Wait;
      function Passed return Boolean;
   private
      Reports : Natural := 0;
      All_OK  : Boolean := True;
   end Results;

   protected body Results is
      procedure Report (Lightweight : Boolean) is
      begin
         Reports := Reports + 1;
         All_OK := All_OK and (Lightweight = Expected_Lightweight);
      end Report;

      entry Wait when Reports = 2 is
      begin
         null;
      end Wait;

      function Passed return Boolean
      is (All_OK);
   end Results;

   task Implicit_Default;

   task type Selected_Worker (Model : Flyology.Execution_Model) is
      pragma Task_Info (Model);
   end Selected_Worker;

   task body Implicit_Default is
   begin
      Results.Report (Flyology.IO.Is_Lightweight_Task);
   end Implicit_Default;

   task body Selected_Worker is
   begin
      Results.Report (Flyology.IO.Is_Lightweight_Task);
   end Selected_Worker;

   Explicit_Default : Selected_Worker (Flyology.Project_Default);
   pragma Unreferenced (Implicit_Default, Explicit_Default);
begin
   if Flyology.IO.Is_Lightweight_Task then
      raise Program_Error with "environment task became a lightweight fiber";
   end if;

   if Ada.Command_Line.Argument_Count /= 1
     or else (Ada.Command_Line.Argument (1) /= "native"
              and then Ada.Command_Line.Argument (1) /= "lightweight")
   then
      raise Program_Error with "expected native or lightweight policy argument";
   end if;

   Results.Wait;
   if not Results.Passed then
      raise Program_Error with "project default execution policy was ignored";
   end if;
end Default_Policy_Smoke;
