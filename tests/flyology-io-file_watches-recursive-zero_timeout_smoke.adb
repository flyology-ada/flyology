with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Text_IO;
with Flyology.Operations;

--  Descendant visibility observes the actual source without changing runtime
--  hooks or relying on watcher representation. Setup failures fail the test.

procedure Flyology.IO.File_Watches.Recursive.Zero_Timeout_Smoke is
   package Ops renames Flyology.Operations;
   use type Ops.Terminal_Outcome;
   use type Flyology.Execution_Model;

   Test_Root  : constant String :=
     Ada.Environment_Variables.Value ("FLYOLOGY_TEST_TEMP_ROOT") & "/file-watch-zero-timeout";
   All_Passed : Boolean := True;

   procedure Require (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Require;

   procedure Write_File (Path : String; Append : Boolean := False) is
      File : Ada.Text_IO.File_Type;
   begin
      if Append then
         Ada.Text_IO.Open (File, Ada.Text_IO.Append_File, Path);
      else
         Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Path);
      end if;
      Ada.Text_IO.Put_Line (File, "changed");
      Ada.Text_IO.Close (File);
   end Write_File;

   procedure Establish_Readiness (Source : Descriptor; Label : String) is
   begin
      for Attempt in 1 .. 200 loop
         if Wait (Source, For_Read, 0.0) then
            Ada.Text_IO.Put_Line
              (Label & " kernel_readable=true source=" & Source'Image & " attempt=" & Attempt'Image);
            return;
         end if;
         delay 0.01;
      end loop;
      raise Program_Error with Label & " setup failed: kernel readiness absent after bounded probes";
   end Establish_Readiness;

   procedure Print_Event (Label : String; Event : File_Event; Outcome : Wait_Outcome) is
   begin
      Ada.Text_IO.Put_Line (Label & " outcome=" & Outcome'Image & " watch=" & Event.Watch'Image);
      for Kind in Change_Kind loop
         if Event.Changes (Kind) then
            Ada.Text_IO.Put_Line (Label & " hint=" & Kind'Image);
         end if;
      end loop;
   end Print_Event;

   procedure Exercise (Mode, Root, Lane : String; Kind : Flyology.Execution_Model; Tree : Boolean) is
      Label  : constant String := Lane & (if Tree then " recursive" else " file");
      Path   : constant String := Root & "/" & Lane & (if Tree then "-tree" else "-file");
      Passed : Boolean := False
      with Atomic;
      task type Observer is
         pragma Task_Info (Kind);
      end Observer;
      task body Observer is
         Set          : aliased Ops.Completion_Set (4);
         Batch        : Ops.Completion_Batch (4);
         Scoped_Ready : Boolean := True;
      begin
         Require (Is_Lightweight_Task = (Kind = Flyology.Lightweight_Task), Label & " lane mismatch");
         if Tree then
            declare
               W : aliased Recursive_Watcher (Capacity => 2);
               E : Recursive_Event;
               O : Wait_Outcome;
            begin
               W.Open (Path);
               Require (W.Directory_Count = 1 and then W.Coverage_Is_Complete, Label & " bad setup");
               Write_File (Path & "/target.txt");
               Establish_Readiness (W.Source.Native_Source, Label);
               if Mode = "synchronous-zero" then
                  W.Next (E, O, 0.0);
                  Ada.Text_IO.Put_Line (Label & " synchronous outcome=" & O'Image);
                  Require (O = Ready and then E.Changes (Contents_Changed), Label & " sync control failed");
               else
                  for Attempt in 1 .. (if Mode = "scoped-zero" then 3 else 1) loop
                     Require
                       (Wait (W.Source.Native_Source, For_Read, 0.0) = (Attempt = 1 or else not Scoped_Ready),
                        Label & " unexpected native readiness");
                     declare
                        Op : Next_Operation :=
                          Next
                            (Set'Access, W'Unchecked_Access, (if Mode = "scoped-positive" then 1.0 else 0.0));
                     begin
                        while not Ops.Is_Terminal (Op) loop
                           Ops.Wait_Some (Set, Batch);
                        end loop;
                        Require (Ops.Outcome (Op) = Ops.Succeeded, Label & " scoped provider failed");
                        Finish (Op, E, O);
                        Ada.Text_IO.Put_Line
                          (Label
                           & " scoped attempt="
                           & Attempt'Image
                           & " outcome="
                           & O'Image
                           & " contents="
                           & E.Changes (Contents_Changed)'Image
                           & " directories="
                           & E.Directory_Count'Image
                           & " coverage="
                           & E.Coverage_Complete'Image);
                        if Attempt = 1 then
                           Scoped_Ready := O = Ready and then E.Changes (Contents_Changed);
                        else
                           Require
                             (O = Timed_Out and then E.Changes = No_Changes,
                              Label & " drained scoped poll returned a hint");
                        end if;
                     end;
                  end loop;
                  if Mode = "scoped-zero" then
                     W.Next (E, O, 0.0);
                     Ada.Text_IO.Put_Line (Label & " synchronous-after outcome=" & O'Image);
                     Require
                       ((if Scoped_Ready
                         then O = Timed_Out and then E.Changes = No_Changes
                         else O = Ready and then E.Changes (Contents_Changed)),
                        Label & " sync-after failed");
                  end if;
                  Require (Scoped_Ready, Label & " scoped polling missed established kernel event");
               end if;
            end;
         else
            declare
               W         : aliased Watcher (Capacity => 2);
               Id, Other : Watch_Id;
               E         : File_Event;
               O         : Wait_Outcome;
            begin
               W.Open;
               Id := W.Add (Path);
               if Mode = "pending" then
                  Other := W.Add (Path);
               end if;
               Write_File (Path, Append => True);
               Establish_Readiness (W.Native_Source, Label);
               if Mode = "synchronous-zero" or else Mode = "pending" then
                  W.Next (E, O, 0.0);
                  Print_Event (Label & " synchronous", E, O);
                  Require (O = Ready and then E.Changes (Contents_Changed), Label & " sync control failed");
                  if Mode = "pending" then
                     Require (E.Watch = Id or else E.Watch = Other, Label & " unknown control identity");
                     if E.Watch = Id then
                        Id := Other;
                     end if;
                  else
                     Require (E.Watch = Id, Label & " wrong control identity");
                  end if;
               end if;
               if Mode /= "synchronous-zero" then
                  for Attempt in 1 .. (if Mode = "scoped-zero" then 3 else 1) loop
                     if Mode /= "pending" then
                        Require
                          (Wait (W.Native_Source, For_Read, 0.0) = (Attempt = 1 or else not Scoped_Ready),
                           Label & " unexpected native readiness");
                     end if;
                     declare
                        Op : File_Watches.Next_Operation :=
                          File_Watches.Next
                            (Set'Access, W'Unchecked_Access, (if Mode = "scoped-positive" then 1.0 else 0.0));
                     begin
                        while not Ops.Is_Terminal (Op) loop
                           Ops.Wait_Some (Set, Batch);
                        end loop;
                        Require (Ops.Outcome (Op) = Ops.Succeeded, Label & " scoped provider failed");
                        File_Watches.Finish (Op, E, O);
                        Print_Event (Label & " scoped attempt=" & Attempt'Image, E, O);
                        if Attempt = 1 then
                           Scoped_Ready :=
                             O = Ready and then E.Watch = Id and then E.Changes (Contents_Changed);
                        else
                           Require
                             (O = Timed_Out and then E.Watch = No_Watch and then E.Changes = No_Changes,
                              Label & " drained scoped poll returned an event");
                        end if;
                     end;
                  end loop;
                  if Mode = "scoped-zero" then
                     W.Next (E, O, 0.0);
                     Print_Event (Label & " synchronous-after", E, O);
                     Require
                       ((if Scoped_Ready
                         then O = Timed_Out and then E.Watch = No_Watch and then E.Changes = No_Changes
                         else O = Ready and then E.Watch = Id and then E.Changes (Contents_Changed)),
                        Label & " sync-after failed");
                  end if;
                  Require (Scoped_Ready, Label & " scoped polling missed established kernel event");
               end if;
            end;
         end if;
         Passed := True;
      exception
         when Error : others =>
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error, Label & " FAIL " & Ada.Exceptions.Exception_Information (Error));
      end Observer;
   begin
      if Tree then
         Ada.Directories.Create_Directory (Path);
      else
         Write_File (Path);
      end if;
      declare
         Worker : Observer;
      begin
         null;
      end;
      All_Passed := All_Passed and then Passed;
   end Exercise;
   procedure Exercise_Mode (Mode : String) is
      Root : constant String := Test_Root & "/" & Mode;
   begin
      Ada.Directories.Create_Directory (Root);
      Ada.Text_IO.Put_Line ("mode=" & Mode);
      Exercise (Mode, Root, "native", Flyology.Native_Task, False);
      Exercise (Mode, Root, "lightweight", Flyology.Lightweight_Task, False);
      if Mode /= "pending" then
         Exercise (Mode, Root, "native", Flyology.Native_Task, True);
         Exercise (Mode, Root, "lightweight", Flyology.Lightweight_Task, True);
      end if;
   end Exercise_Mode;
begin
   if Ada.Directories.Exists (Test_Root) then
      Ada.Directories.Delete_Tree (Test_Root);
   end if;
   Ada.Directories.Create_Directory (Test_Root);
   Exercise_Mode ("scoped-zero");
   Exercise_Mode ("synchronous-zero");
   Exercise_Mode ("scoped-positive");
   Exercise_Mode ("pending");
   Ada.Directories.Delete_Tree (Test_Root);
   Require (All_Passed, "zero-timeout watcher checks failed");
end Flyology.IO.File_Watches.Recursive.Zero_Timeout_Smoke;
