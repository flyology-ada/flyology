with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Text_IO;
with Flyology;
with Flyology.IO;
with Flyology.IO.File_Watches;
with Flyology.IO.File_Watches.Recursive;
with Flyology.Operations;
with Interfaces.C;
with System;

procedure File_Watches_Recursive_Smoke is
   package Watches renames Flyology.IO.File_Watches;
   package Recursive renames Flyology.IO.File_Watches.Recursive;
   package Operations renames Flyology.Operations;

   use type Flyology.IO.Wait_Outcome;
   use type Interfaces.C.int;

   Test_Root : constant String :=
     Ada.Environment_Variables.Value
       ("FLYOLOGY_TEST_TEMP_ROOT", "/tmp")
     & "/file-watches-recursive-smoke";

   function Open_FD_Count return Interfaces.C.int
     with Import,
          Convention    => C,
          External_Name => "flyology_test_open_fd_count";

   function C_Symlink
     (Target : System.Address;
      Link   : System.Address) return Interfaces.C.int
     with Import,
          Convention    => C,
          External_Name => "symlink";

   procedure Require (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Require;

   procedure Reset_Directory (Path : String) is
   begin
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_Tree (Path);
      end if;
      Ada.Directories.Create_Path (Path);
   end Reset_Directory;

   procedure Create_File (Path : String) is
      File : Ada.Text_IO.File_Type;
   begin
      Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Path);
      Ada.Text_IO.Put_Line (File, "changed");
      Ada.Text_IO.Close (File);
   end Create_File;

   procedure Create_Symlink (Target : String; Link : String) is
      C_Target : aliased String (1 .. Target'Length + 1);
      C_Link   : aliased String (1 .. Link'Length + 1);
   begin
      C_Target (1 .. Target'Length) := Target;
      C_Target (C_Target'Last) := ASCII.NUL;
      C_Link (1 .. Link'Length) := Link;
      C_Link (C_Link'Last) := ASCII.NUL;
      Require
        (C_Symlink (C_Target'Address, C_Link'Address) = 0,
         "could not create recursive-watch symbolic link");
   end Create_Symlink;

   procedure Exercise (Lane : String; Kind : Flyology.Execution_Model) is
      Lane_Root : constant String := Test_Root & "/" & Lane;
      Tree_Root : constant String := Lane_Root & "/tree";
      First     : constant String := Tree_Root & "/first";
      Second    : constant String := First & "/second";
      Third     : constant String := Second & "/third";
      Loop_Link : constant String := Tree_Root & "/loop";
      Outside   : constant String := Lane_Root & "/outside";
      Moved     : constant String := Outside & "/moved";
      Bounded_Root : constant String := Lane_Root & "/bounded";
      Bounded_Child : constant String := Bounded_Root & "/child";
      Bounded_Link : constant String := Bounded_Child & "/loop";
      Overflow  : constant String := Bounded_Root & "/overflow";
      Gone_Root : constant String := Lane_Root & "/gone";
      Gone_Child : constant String := Gone_Root & "/child";
      Passed : Boolean := False with Atomic;

      task type Observer is
         pragma Task_Info (Kind);
      end Observer;

      task body Observer is
         procedure Lane_Require
           (Condition : Boolean;
            Message   : String) is
         begin
            Require (Condition, Lane & ": " & Message);
         end Lane_Require;

         Event   : Recursive.Recursive_Event;
         Outcome : Flyology.IO.Wait_Outcome;
      begin
         --  Initial discovery includes every real directory and skips a
         --  symbolic link that would otherwise form a traversal cycle.
         declare
            Before : constant Interfaces.C.int := Open_FD_Count;
            Item   : aliased Recursive.Recursive_Watcher (Capacity => 8);
            Rejected : Boolean := False;
         begin
            Item.Open (Tree_Root);
            Lane_Require (Item.Is_Open, "recursive watcher did not open");
            Lane_Require
              (Item.Directory_Count = 3,
               "initial discovery did not register three real directories");
            Lane_Require
              (Item.Coverage_Is_Complete,
               "initial recursive coverage was incomplete");
            Item.Open (Tree_Root);
            begin
               Item.Open (Outside);
            exception
               when Flyology.IO.Device_Error => Rejected := True;
            end;
            Lane_Require
              (Rejected, "open recursive watcher accepted another root");

            --  The recursive overload is a real composite operation: its
            --  hidden ordinary-watcher child occupies one slot, while only
            --  the reconciled parent participates in the public success gate.
            declare
               Set : aliased Operations.Completion_Set (3);
               Watch : aliased Recursive.Next_Operation :=
                 Recursive.Next
                   (Set'Access, Item'Unchecked_Access, Timeout => 2.0);
               Ready_Gate : Operations.Gate_Operation :=
                 Operations.Wait_For_Success
                   (Set'Access, [1 => Operations.Reference (Watch)]);
               Matches : Operations.Completion_Batch (Set.Capacity);
            begin
               Ada.Directories.Create_Directory (Third);
               Operations.Wait_All (Set);
               Operations.Finish (Ready_Gate, Matches);
               Recursive.Finish (Watch, Event, Outcome);
               Lane_Require
                 (Matches.Count = 1,
                  "recursive success gate exposed its hidden child");
            end;
            Lane_Require
              (Outcome = Flyology.IO.Ready,
               "new subdirectory did not wake recursive watcher");
            Lane_Require
              (Event.Registrations_Changed
               and then Event.Directory_Count = 4
               and then Event.Coverage_Complete,
               "new subdirectory was not reconciled");

            Create_File (Third & "/payload.txt");
            Item.Next (Event, Outcome, Timeout => 2.0);
            Lane_Require
              (Outcome = Flyology.IO.Ready
               and then Event.Changes (Watches.Contents_Changed),
               "newly registered directory did not report file creation");
            Lane_Require
              (not Event.Registrations_Changed
               and then Event.Directory_Count = 4,
               "file creation changed recursive registrations");

            Ada.Directories.Rename (Third, Moved);
            Item.Next (Event, Outcome, Timeout => 2.0);
            Lane_Require
              (Outcome = Flyology.IO.Ready
               and then Event.Registrations_Changed
               and then Event.Directory_Count = 3,
               "moved subtree registration was not removed");

            Ada.Directories.Create_Directory (Third);
            Item.Refresh (Event);
            Lane_Require
              (Event.Registrations_Changed
               and then Event.Directory_Count = 4,
               "explicit refresh did not add a discovered directory");
            Ada.Directories.Delete_Directory (Third);
            Item.Refresh (Event);
            Lane_Require
              (Event.Registrations_Changed
               and then Event.Directory_Count = 3,
               "explicit refresh did not remove an obsolete directory");

            for Round in 1 .. 16 loop
               declare
                  Path : constant String :=
                    Second & "/churn-" & Integer'Image (Round);
               begin
                  Ada.Directories.Create_Directory (Path);
                  Item.Next (Event, Outcome, Timeout => 2.0);
                  Lane_Require
                    (Outcome = Flyology.IO.Ready
                     and then Event.Directory_Count = 4,
                     "recursive add churn did not reconcile");
                  Ada.Directories.Delete_Directory (Path);
                  Item.Next (Event, Outcome, Timeout => 2.0);
                  Lane_Require
                    (Outcome = Flyology.IO.Ready
                     and then Event.Directory_Count = 3,
                     "recursive remove churn did not reconcile");
               end;
            end loop;

            for Attempt in 1 .. 64 loop
               Item.Next (Event, Outcome, Timeout => 0.0);
               exit when Outcome = Flyology.IO.Timed_Out;
            end loop;
            Lane_Require
              (Outcome = Flyology.IO.Timed_Out,
               "recursive watcher did not quiesce after bounded drain");

            --  Immediate timeout and pending cancellation both drain and
            --  release the hidden child before returning the watcher borrow.
            declare
               Set : aliased Operations.Completion_Set (2);
               Watch : Recursive.Next_Operation :=
                 Recursive.Next
                   (Set'Access, Item'Unchecked_Access, Timeout => 0.0);
            begin
               Operations.Wait_All (Set);
               Recursive.Finish (Watch, Event, Outcome);
               Lane_Require
                 (Outcome = Flyology.IO.Timed_Out,
                  "recursive operation did not retain immediate timeout");
            end;
            declare
               Set : aliased Operations.Completion_Set (2);
               Watch : Recursive.Next_Operation :=
                 Recursive.Next
                   (Set'Access, Item'Unchecked_Access,
                    Timeout => Flyology.IO.Infinite);
               Was_Cancelled : Boolean := False;
            begin
               Operations.Cancel (Watch);
               Operations.Wait_All (Set);
               begin
                  Recursive.Finish (Watch, Event, Outcome);
               exception
                  when Operations.Operation_Cancelled =>
                     Was_Cancelled := True;
               end;
               Lane_Require
                 (Was_Cancelled,
                  "recursive operation cancellation was not retained");
            end;

            --  A watcher has one serialized scoped borrow. A second root can
            --  terminalize as failed without disturbing the pending first
            --  operation or leaking its own set slot.
            declare
               Set : aliased Operations.Completion_Set (3);
               First_Watch : Recursive.Next_Operation :=
                 Recursive.Next
                   (Set'Access, Item'Unchecked_Access,
                    Timeout => Flyology.IO.Infinite);
               Second_Watch : Recursive.Next_Operation :=
                 Recursive.Next
                   (Set'Access, Item'Unchecked_Access,
                    Timeout => Flyology.IO.Infinite);
               Borrow_Rejected : Boolean := False;
               Borrow_Preserved : Boolean := False;
               First_Cancelled : Boolean := False;
            begin
               begin
                  Recursive.Finish (Second_Watch, Event, Outcome);
               exception
                  when Flyology.IO.Device_Error =>
                     Borrow_Rejected := True;
               end;
               Lane_Require
                 (Borrow_Rejected,
                  "second recursive scoped borrow was not rejected");
               begin
                  Item.Refresh (Event);
               exception
                  when Flyology.IO.Device_Error =>
                     Borrow_Preserved := True;
               end;
               Lane_Require
                 (Borrow_Preserved,
                  "rejected recursive operation released another borrow");
               Operations.Cancel (First_Watch);
               Operations.Wait_All (Set);
               begin
                  Recursive.Finish (First_Watch, Event, Outcome);
               exception
                  when Operations.Operation_Cancelled =>
                     First_Cancelled := True;
               end;
               Lane_Require
                 (First_Cancelled,
                  "first recursive operation did not remain cancellable");
            end;

            --  Controlled finalization is the safety net for an abandoned
            --  pending parent and its hidden child. It must release the
            --  watcher borrow before the next synchronous operation.
            declare
               Set : aliased Operations.Completion_Set (2);
               Watch : Recursive.Next_Operation :=
                 Recursive.Next
                   (Set'Access, Item'Unchecked_Access,
                    Timeout => Flyology.IO.Infinite);
               pragma Unreferenced (Watch);
            begin
               null;
            end;
            Item.Refresh (Event);
            Item.Close;
            Lane_Require
              (Open_FD_Count = Before,
               "recursive watcher lifecycle leaked a descriptor");
         end;

         --  The default capacity is usable without a discriminant, and the
         --  final symbolic-link component of the selected root is followed.
         declare
            Item : Recursive.Recursive_Watcher;
            Missing_Rejected : Boolean := False;
            File_Rejected : Boolean := False;
         begin
            begin
               Item.Open (Lane_Root & "/missing");
            exception
               when Flyology.IO.Device_Error => Missing_Rejected := True;
            end;
            Lane_Require
              (Missing_Rejected and then not Item.Is_Open,
               "missing recursive root did not raise Device_Error");
            begin
               Item.Open (Moved & "/payload.txt");
            exception
               when Flyology.IO.Device_Error => File_Rejected := True;
            end;
            Lane_Require
              (File_Rejected and then not Item.Is_Open,
               "file recursive root did not raise Device_Error");
            Item.Open (Loop_Link);
            Lane_Require
              (Item.Directory_Count = 3,
               "recursive root symbolic link was not followed");
            Item.Close;
         end;

         --  Initial capacity overflow is transactional and leaves the object
         --  closed without retaining any native registrations.
         declare
            Before : constant Interfaces.C.int := Open_FD_Count;
            Item   : Recursive.Recursive_Watcher (Capacity => 2);
            Rejected : Boolean := False;
         begin
            begin
               Item.Open (Tree_Root);
            exception
               when Flyology.IO.Device_Error => Rejected := True;
            end;
            Lane_Require (Rejected, "initial tree capacity overflow passed");
            Lane_Require (not Item.Is_Open, "overflow left watcher open");
            Lane_Require
              (Open_FD_Count = Before,
               "initial tree capacity overflow leaked a descriptor");
         end;

         --  Growth beyond the bound preserves the previous complete set and
         --  reports lost coverage. A later deletion restores full coverage.
         declare
            Item : Recursive.Recursive_Watcher (Capacity => 2);
         begin
            Item.Open (Bounded_Root);
            Lane_Require
              (Item.Directory_Count = 2,
               "bounded tree followed a nested symbolic link");
            Ada.Directories.Create_Directory (Overflow);
            Item.Next (Event, Outcome, Timeout => 2.0);
            Lane_Require
              (Outcome = Flyology.IO.Ready
               and then Event.Changes (Watches.Events_Lost)
               and then not Event.Coverage_Complete
               and then Event.Directory_Count = 2,
               "dynamic capacity overflow did not report lost coverage");
            Ada.Directories.Delete_Directory (Overflow);
            Item.Refresh (Event);
            Lane_Require
              (Event.Coverage_Complete
               and then Item.Coverage_Is_Complete,
               "explicit refresh did not recover bounded coverage");

            Ada.Directories.Create_Directory (Overflow);
            Ada.Directories.Delete_Directory (Overflow);
            Item.Refresh (Event);
            Lane_Require
              (Event.Coverage_Complete and then Event.Directory_Count = 2,
               "explicit refresh did not preserve bounded coverage");
            Item.Close;
         end;

         --  Removing the root produces a terminal tree event and closes the
         --  watcher so callers can reopen it only after the root is recreated.
         declare
            Before : constant Interfaces.C.int := Open_FD_Count;
            Item   : Recursive.Recursive_Watcher (Capacity => 4);
         begin
            Item.Open (Gone_Root);
            Ada.Directories.Delete_Tree (Gone_Root);
            Item.Next (Event, Outcome, Timeout => 2.0);
            Lane_Require
              (Outcome = Flyology.IO.Ready
               and then Event.Changes (Watches.Identity_Changed)
               and then Event.Changes (Watches.Watch_Invalidated),
               "removed root did not report terminal invalidation");
            Lane_Require
              (not Item.Is_Open and then Event.Directory_Count = 0,
               "removed root did not close recursive watcher");
            Item.Close;
            Lane_Require
              (Open_FD_Count = Before,
               "root invalidation leaked a descriptor");
         end;

         Ada.Directories.Delete_File (Loop_Link);
         Ada.Directories.Delete_File (Bounded_Link);
         Passed := True;
      exception
         when Error : others =>
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               Ada.Exceptions.Exception_Information (Error));
            Passed := False;
      end Observer;
   begin
      Reset_Directory (Lane_Root);
      Ada.Directories.Create_Path (Second);
      Ada.Directories.Create_Directory (Outside);
      Create_Symlink (Tree_Root, Loop_Link);
      Ada.Directories.Create_Path (Bounded_Child);
      Create_Symlink (Bounded_Root, Bounded_Link);
      Ada.Directories.Create_Path (Gone_Child);
      declare
         Worker : Observer;
      begin
         null;
      end;
      if not Passed then
         raise Program_Error with Lane & " recursive watcher checks failed";
      end if;
      Ada.Directories.Delete_Tree (Lane_Root);
   end Exercise;
begin
   Reset_Directory (Test_Root);
   Exercise ("native", Flyology.Native_Task);
   Exercise ("lightweight", Flyology.Lightweight_Task);
   Ada.Directories.Delete_Tree (Test_Root);
end File_Watches_Recursive_Smoke;
